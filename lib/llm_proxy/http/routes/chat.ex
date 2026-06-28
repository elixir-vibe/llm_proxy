defmodule LLMProxy.HTTP.Routes.Chat do
  @moduledoc """
  OpenAI Chat Completions route adapter for authenticated HTTP requests and SSE streams.
  """
  use Plug.Router

  require Logger

  alias LLMProxy.Actor
  alias LLMProxy.HTTP
  alias LLMProxy.Plugs.{Auth, QuotaCheck}
  alias LLMProxy.Protocol.{OpenAI, Request}
  alias LLMProxy.Provider
  alias LLMProxy.Providers.Result
  alias LLMProxy.Stream.SSEWriter
  alias LLMProxy.Trace

  plug(Auth)
  plug(QuotaCheck)
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
  end

  defp handle_stream(conn, api_key, %Request{} = request, meta) do
    {conn, request_id} = Trace.ensure_conn(conn)

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
  end

  defp handle_provider_error(
         conn,
         {:provider, %Result{error: error, status: status, provider: provider}}
       ) do
    log_provider_error(provider, error, status)
    HTTP.send_json(conn, status, %{error: error})
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

  defp finish_stream(conn, %Result{
         kind: :stream,
         stream: stream,
         provider: used_provider,
         model: used_model
       }) do
    conn = SSEWriter.start_sse(conn)
    from_protocol = provider_protocol(used_provider)

    pipe_stream(conn, stream, from_protocol, used_model)
  end

  defp pipe_stream(conn, stream, from_protocol, model) do
    Enum.reduce_while(stream, conn, fn event, conn ->
      conn
      |> write_stream_event(OpenAI.stream_event(event.data, from_protocol, model))
    end)
    |> then(fn conn ->
      {:ok, conn} = SSEWriter.write_done(conn)
      conn
    end)
  end

  defp write_stream_event(conn, nil), do: {:cont, conn}

  defp write_stream_event(conn, data) do
    case SSEWriter.write_event(conn, data) do
      {:ok, conn} -> {:cont, conn}
      {:error, _reason} -> {:halt, conn}
    end
  end

  defp provider_protocol(provider) do
    if function_exported?(provider, :native_protocol, 0),
      do: provider.native_protocol(),
      else: :openai
  end

  defp log_provider_error(nil, error, status),
    do: Logger.error("Provider error (#{status}): #{error}")

  defp log_provider_error(provider, error, status) do
    Logger.error("#{provider.name()} error (#{status}): #{error}")
  end
end
