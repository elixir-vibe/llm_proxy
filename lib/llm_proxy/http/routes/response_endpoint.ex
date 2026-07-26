defmodule LLMProxy.HTTP.Routes.ResponseEndpoint do
  @moduledoc """
  OpenAI Responses route adapter that passes native request and stream events through LLMProxy execution.
  """
  use Plug.Router

  require Logger

  alias LLMProxy.Accounting.UsageTracking
  alias LLMProxy.Actor
  alias LLMProxy.HTTP
  alias LLMProxy.HTTP.Routes.Passthrough
  alias LLMProxy.Plugs.{Auth, JSONBodyParser, QuotaCheck}
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Provider
  alias LLMProxy.Providers.Result
  alias LLMProxy.Stream.{Event, Heartbeat, SSEWriter}
  alias LLMProxy.{Telemetry, Trace, Usage}
  alias LLMProxy.TokenPool.Server, as: TokenPool

  plug(Auth)
  plug(QuotaCheck)
  plug(JSONBodyParser)
  plug(:match)
  plug(:dispatch)

  post "/" do
    handle_responses(conn)
  end

  match _ do
    send_error(conn, 404, "not_found_error", "Not found")
  end

  defp handle_responses(conn) do
    {conn, trace_id} = Trace.ensure_conn(conn)
    api_key = conn.assigns.api_key
    body = conn.body_params
    model = body["model"]

    case Request.parse(:openai_responses, body) do
      {:ok, request} ->
        Logger.debug(
          "Responses request from #{api_key.name} model=#{model} stream=#{responses_stream?(request)}"
        )

        dispatch_provider(conn, normalize_stream(request), api_key, trace_id)

      {:error, %Request.Error{} = error} ->
        send_error(conn, 400, error.code, error.message)
    end
  end

  defp normalize_stream(%Request{stream: false} = request), do: request

  defp normalize_stream(%Request{} = request),
    do: %{request | body: Map.put(request.body, "stream", true), stream: true}

  defp responses_stream?(%Request{} = request), do: normalize_stream(request).stream

  defp dispatch_provider(conn, %Request{stream: true} = request, api_key, trace_id) do
    LLMProxy.Drain.track(:stream, HTTP.request_meta(conn, trace_id, :responses), fn ->
      case Provider.stream_native(request, Actor.from_api_key(api_key),
             route: :responses,
             trace_id: trace_id,
             api_name: "Responses API"
           ) do
        {:ok, %Result{kind: :stream} = result} ->
          Passthrough.send_result(conn, result, api_key, trace_id, passthrough_result_handler())

        {:error, reason} ->
          handle_provider_error(conn, reason)
      end
    end)
    |> handle_drain_race(conn)
  end

  defp dispatch_provider(conn, %Request{} = request, api_key, trace_id) do
    LLMProxy.Drain.track(:request, HTTP.request_meta(conn, trace_id, :responses), fn ->
      case Provider.call_native(request, Actor.from_api_key(api_key),
             route: :responses,
             trace_id: trace_id,
             api_name: "Responses API"
           ) do
        {:ok, %Result{kind: :response} = result} ->
          Passthrough.send_result(conn, result, api_key, trace_id, passthrough_result_handler())

        {:error, reason} ->
          handle_provider_error(conn, reason)
      end
    end)
    |> handle_drain_race(conn)
  end

  defp passthrough_result_handler do
    Passthrough.result_handler(&handle_non_stream/6, &handle_stream/7)
  end

  defp handle_provider_error(conn, reason) do
    Passthrough.send_error(
      conn,
      reason,
      Passthrough.error_handler(
        &send_error/4,
        fn _status -> "api_error" end,
        &mark_rate_limited_if_needed/1
      )
    )
  end

  defp mark_rate_limited_if_needed(%Result{status: 429, token: token}) when not is_nil(token) do
    TokenPool.mark_rate_limited(token)
  end

  defp mark_rate_limited_if_needed(_result), do: :ok

  defp handle_non_stream(conn, provider, response, api_key, model, trace_id) do
    usage = extract_usage(response)
    UsageTracking.track_usage(api_key, model, usage, tracking_opts(provider, trace_id))
    HTTP.send_json(conn, 200, response)
  end

  defp handle_stream(conn, provider, stream, api_key, model, token, trace_id) do
    telemetry = Telemetry.stream_context(provider.name(), model, trace_id)

    outcome =
      stream
      |> Heartbeat.wrap(telemetry: telemetry)
      |> Enum.reduce_while({:pending, conn, Usage.zero()}, fn
        %Heartbeat.Failure{reason: reason}, {:pending, conn, usage} ->
          {:halt, {:preflight_failure, conn, usage, reason}}

        %Heartbeat.Failure{reason: reason}, {:started, conn, usage} ->
          conn = write_stream_failure(conn, provider, model, token, reason)
          {:halt, {:started, conn, usage}}

        event, {:pending, conn, usage} ->
          conn = SSEWriter.start_sse(conn)
          reduce_stream_item(event, {:started, conn, usage})

        event, {:started, _conn, _usage} = state ->
          reduce_stream_item(event, state)
      end)

    finish_stream(outcome, provider, api_key, model, token, trace_id)
  end

  defp reduce_stream_item(%Heartbeat{}, {:started, conn, usage}) do
    case SSEWriter.write_heartbeat(conn) do
      {:ok, conn} -> {:cont, {:started, conn, usage}}
      {:error, _reason} -> {:halt, {:started, conn, usage}}
    end
  end

  defp reduce_stream_item(%Event{} = event, {:started, conn, usage}) do
    usage = merge_stream_usage(usage, event)

    case SSEWriter.write_event(conn, encode_stream_event(event.data)) do
      {:ok, conn} -> {:cont, {:started, conn, usage}}
      {:error, _reason} -> {:halt, {:started, conn, usage}}
    end
  end

  defp finish_stream(
         {:preflight_failure, conn, _usage, reason},
         provider,
         _api_key,
         model,
         token,
         _trace_id
       ) do
    error = Result.stream_failure(provider, model, token, reason)
    handle_provider_error(conn, {:provider, error})
  end

  defp finish_stream({:pending, conn, usage}, provider, api_key, model, _token, trace_id) do
    conn = SSEWriter.start_sse(conn)
    finish_started_stream(conn, usage, provider, api_key, model, trace_id)
  end

  defp finish_stream({:started, conn, usage}, provider, api_key, model, _token, trace_id) do
    finish_started_stream(conn, usage, provider, api_key, model, trace_id)
  end

  defp finish_started_stream(conn, usage, provider, api_key, model, trace_id) do
    conn =
      case SSEWriter.write_done(conn) do
        {:ok, conn} -> conn
        {:error, _reason} -> conn
      end

    UsageTracking.track_usage(api_key, model, usage, tracking_opts(provider, trace_id))
    conn
  end

  defp write_stream_failure(conn, provider, model, token, reason) do
    error = Result.stream_failure(provider, model, token, reason)
    error_event = %{"type" => "error", "error" => Result.client_error(error)}

    case SSEWriter.write_event(conn, error_event) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  defp encode_stream_event(event) when is_binary(event), do: event
  defp encode_stream_event(event), do: Jason.encode!(event)

  defp merge_stream_usage(_usage, %Event{usage: event_usage}) when not is_nil(event_usage),
    do: event_usage

  defp merge_stream_usage(_usage, %Event{
         data: %{
           "type" => "response.completed",
           "response" => %{"usage" => resp_usage}
         }
       })
       when is_map(resp_usage) do
    Usage.from_responses(resp_usage)
  end

  defp merge_stream_usage(usage, _event), do: usage

  defp extract_usage(response) do
    usage = response["usage"] || %{}
    Usage.from_responses(usage)
  end

  defp tracking_opts(provider, trace_id) do
    %{provider: provider.name(), metadata: %{"trace_id" => trace_id}}
  end

  defp handle_drain_race({:error, :draining}, conn) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", "30")
    |> send_error(503, "draining", "LLMProxy is draining and not accepting new requests")
  end

  defp handle_drain_race(result, _conn), do: result

  defp send_error(conn, status, type, message) do
    HTTP.send_json(conn, status, %{error: %{type: type, message: message}})
  end
end
