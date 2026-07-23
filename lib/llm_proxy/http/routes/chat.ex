defmodule LLMProxy.HTTP.Routes.Chat do
  @moduledoc """
  OpenAI Chat Completions route adapter for authenticated HTTP requests and SSE streams.
  """
  use Plug.Router

  require Logger

  alias LLMProxy.Actor
  alias LLMProxy.HTTP
  alias LLMProxy.Plugs.{Auth, JSONBodyParser, QuotaCheck}
  alias LLMProxy.Protocol.{OpenAI, Request}
  alias LLMProxy.Provider
  alias LLMProxy.Providers.Result
  alias LLMProxy.Stream.{Heartbeat, SSEWriter}
  alias LLMProxy.Trace

  plug(Auth)
  plug(QuotaCheck)
  plug(JSONBodyParser)
  plug(:match)
  plug(:dispatch)

  post "/completions" do
    handle_chat(conn)
  end

  match _ do
    HTTP.send_json(conn, 404, %{error: "Not found"})
  end

  defp handle_chat(conn) do
    api_key = conn.assigns.api_key
    body = conn.body_params

    case Request.parse(:openai_chat, body) do
      {:ok, request} ->
        meta = %{tags: request.tags, metadata: request.metadata}

        if request.stream do
          handle_stream(conn, api_key, request, meta)
        else
          handle_non_stream(conn, api_key, request, meta)
        end

      {:error, %Request.Error{} = error} ->
        HTTP.send_json(conn, 400, %{error: %{code: error.code, message: error.message}})
    end
  end

  defp handle_non_stream(conn, api_key, %Request{} = request, meta) do
    {conn, request_id} = Trace.ensure_conn(conn)

    LLMProxy.Drain.track(:request, HTTP.request_meta(conn, request_id, :chat), fn ->
      case Provider.call(request, Actor.from_api_key(api_key),
             route: :chat,
             trace_id: request_id,
             usage_metadata: Map.to_list(meta)
           ) do
        {:ok, response} ->
          HTTP.send_json(conn, 200, LLMProxy.Response.to_openai(response))

        {:error, reason} ->
          handle_provider_error(conn, reason)
      end
    end)
    |> handle_drain_race(conn)
  end

  defp handle_stream(conn, api_key, %Request{} = request, meta) do
    {conn, request_id} = Trace.ensure_conn(conn)

    LLMProxy.Drain.track(:stream, HTTP.request_meta(conn, request_id, :chat), fn ->
      case Provider.stream(request, Actor.from_api_key(api_key),
             route: :chat,
             trace_id: request_id,
             usage_metadata: Map.to_list(meta)
           ) do
        {:ok, %Result{kind: :stream} = result} ->
          finish_stream(conn, result)

        {:error, reason} ->
          handle_provider_error(conn, reason)
      end
    end)
    |> handle_drain_race(conn)
  end

  defp handle_provider_error(
         conn,
         {:provider, %Result{error: error, status: status, provider: provider} = result}
       ) do
    log_provider_error(provider, error, status)
    HTTP.send_json(conn, status, %{error: provider_error_body(result)})
  end

  defp handle_provider_error(conn, {:permission, reason}) do
    HTTP.send_json(conn, 403, %{error: reason})
  end

  defp handle_provider_error(conn, {:not_found, reason}) do
    HTTP.send_json(conn, 404, %{error: reason})
  end

  defp handle_provider_error(conn, {:guardrail, reason}) do
    HTTP.send_json(conn, 403, %{error: inspect(reason)})
  end

  defp finish_stream(conn, %Result{kind: :stream} = result) do
    from_protocol = provider_protocol(result.provider)

    result.stream
    |> Heartbeat.wrap()
    |> Enum.reduce_while({:pending, conn}, fn
      %Heartbeat.Failure{reason: reason}, {:pending, conn} ->
        {:halt, {:preflight_failure, conn, reason}}

      %Heartbeat.Failure{reason: reason}, {:started, conn} ->
        {:halt, {:started, write_stream_failure(conn, result, reason)}}

      event, {:pending, conn} ->
        conn = SSEWriter.start_sse(conn)
        reduce_stream_item(event, {:started, conn}, from_protocol, result.model)

      event, {:started, _conn} = state ->
        reduce_stream_item(event, state, from_protocol, result.model)
    end)
    |> finish_stream_result(result)
  end

  defp reduce_stream_item(%Heartbeat{}, {:started, conn}, _from_protocol, _model) do
    case SSEWriter.write_heartbeat(conn) do
      {:ok, conn} -> {:cont, {:started, conn}}
      {:error, _reason} -> {:halt, {:started, conn}}
    end
  end

  defp reduce_stream_item(event, {:started, conn}, from_protocol, model) do
    case OpenAI.stream_event(event.data, from_protocol, model) do
      nil ->
        {:cont, {:started, conn}}

      data ->
        case SSEWriter.write_event(conn, data) do
          {:ok, conn} -> {:cont, {:started, conn}}
          {:error, _reason} -> {:halt, {:started, conn}}
        end
    end
  end

  defp finish_stream_result({:preflight_failure, conn, reason}, result) do
    error = Result.stream_failure(result.provider, result.model, result.token, reason)
    handle_provider_error(conn, {:provider, error})
  end

  defp finish_stream_result({:pending, conn}, _result) do
    conn
    |> SSEWriter.start_sse()
    |> write_done()
  end

  defp finish_stream_result({:started, conn}, _result), do: write_done(conn)

  defp write_stream_failure(conn, result, reason) do
    error = Result.stream_failure(result.provider, result.model, result.token, reason)

    case SSEWriter.write_event(conn, %{"error" => Result.client_error(error)}) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  defp write_done(conn) do
    case SSEWriter.write_done(conn) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  defp provider_protocol(provider) do
    if function_exported?(provider, :native_protocol, 0),
      do: provider.native_protocol(),
      else: :openai
  end

  defp handle_drain_race({:error, :draining}, conn), do: drain_rejected(conn)
  defp handle_drain_race(result, _conn), do: result

  defp drain_rejected(conn) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", "30")
    |> HTTP.send_json(503, %{
      error: %{code: "draining", message: "LLMProxy is draining and not accepting new requests"}
    })
  end

  defp provider_error_body(%Result{error: error, provider_body: nil}), do: error

  defp provider_error_body(%Result{error: error, provider_body: provider_body}) do
    %{message: error, details: provider_body}
  end

  defp log_provider_error(nil, error, status),
    do: Logger.error("Provider error (#{status}): #{error}")

  defp log_provider_error(provider, error, status) do
    Logger.error("#{provider.name()} error (#{status}): #{error}")
  end
end
