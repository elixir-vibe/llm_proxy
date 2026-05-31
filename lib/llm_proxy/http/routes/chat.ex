defmodule LLMProxy.HTTP.Routes.Chat do
  @moduledoc false
  use Plug.Router

  require Logger

  alias LLMProxy.AccessControl
  alias LLMProxy.Actor
  alias LLMProxy.Guardrails
  alias LLMProxy.HTTP.Routes.Helpers
  alias LLMProxy.Plugs.{Auth, QuotaCheck}
  alias LLMProxy.Protocol.{OpenAI, Request}
  alias LLMProxy.Provider
  alias LLMProxy.Providers.{Caller, Registry, Result}
  alias LLMProxy.Stream.{Event, SSEWriter}
  alias LLMProxy.Telemetry
  alias LLMProxy.Trace
  alias LLMProxy.Usage
  alias LLMProxy.UsageTracking

  plug(Auth)
  plug(QuotaCheck)
  plug(:match)
  plug(:dispatch)

  post "/completions" do
    handle_chat(conn)
  end

  match _ do
    Helpers.send_json(conn, 404, %{error: "Not found"})
  end

  defp handle_chat(conn) do
    api_key = conn.assigns.api_key
    body = conn.body_params
    model = body["model"]

    with {:ok, request} <- Request.parse(:openai_chat, body),
         model <- request.model,
         :ok <- AccessControl.check_model_access(api_key, model),
         provider when not is_nil(provider) <- Registry.get_provider(model) do
      Logger.debug("Request from #{api_key.name} model=#{model} provider=#{provider.name()}")
      meta = %{tags: request.tags, metadata: request.metadata}

      if request.stream do
        handle_stream(conn, provider, api_key, request, model, meta)
      else
        handle_non_stream(conn, provider, api_key, request, model, meta)
      end
    else
      nil ->
        Helpers.send_json(conn, 404, %{error: "Model '#{model}' not found"})

      {:error, %Request.Error{} = error} ->
        Helpers.send_json(conn, 400, %{error: %{code: error.code, message: error.message}})

      {:error, reason} ->
        Helpers.send_json(conn, 403, %{error: reason})
    end
  end

  defp handle_non_stream(conn, provider, api_key, %Request{} = request, _model, meta) do
    {conn, request_id} = Trace.ensure_conn(conn)

    case Provider.call(request, Actor.from_api_key(api_key),
           route: :chat,
           trace_id: request_id,
           usage_metadata: Map.to_list(meta)
         ) do
      {:ok, response} ->
        Helpers.send_json(conn, 200, response.body)

      {:error, {:provider, %Result{error: error, status: status}}} ->
        Logger.error("#{provider.name()} error (#{status}): #{error}")
        Helpers.send_json(conn, status, %{error: error})

      {:error, {:permission, reason}} ->
        Helpers.send_json(conn, 403, %{error: reason})

      {:error, {:not_found, reason}} ->
        Helpers.send_json(conn, 404, %{error: reason})

      {:error, {:guardrail, reason}} ->
        Helpers.send_json(conn, 403, %{error: inspect(reason)})
    end
  end

  defp handle_stream(conn, provider, api_key, %Request{} = request, model, meta) do
    {conn, request_id} = Trace.ensure_conn(conn)

    case Guardrails.before_request(
           request,
           stream_context(api_key, request, model, trace_id: request_id)
         ) do
      {:ok, request} ->
        do_handle_stream(conn, provider, api_key, request, model, meta, request_id)

      {:error, reason} ->
        Helpers.send_json(conn, 403, %{error: inspect(reason)})
    end
  end

  defp do_handle_stream(conn, provider, api_key, %Request{} = request, model, meta, request_id) do
    UsageTracking.log_user_message(api_key, request.model, "chat", fn ->
      Request.user_text(request)
    end)

    start = System.monotonic_time(:millisecond)

    case Telemetry.with_provider_span(
           provider.name(),
           model,
           :stream,
           fn -> Caller.stream(provider, request, api_key.id, model) end,
           %{"llm_proxy.trace_id" => request_id}
         ) do
      {:ok, %Result{} = result} ->
        finish_stream(conn, result, start, api_key, request, meta, request_id)

      {:error, %Result{error: error, status: status}} ->
        Logger.error("#{provider.name()} stream error (#{status}): #{error}")
        Helpers.send_json(conn, status, %{error: error})
    end
  end

  defp finish_stream(
         conn,
         %Result{stream: stream, provider: used_provider, model: used_model},
         start,
         api_key,
         request,
         meta,
         request_id
       ) do
    conn = SSEWriter.start_sse(conn)
    from_protocol = provider_protocol(used_provider)

    context =
      stream_context(api_key, request, used_model, provider: used_provider, trace_id: request_id)

    {conn, usage, ttft_ms} = pipe_stream(conn, stream, start, from_protocol, used_model, context)
    duration_ms = System.monotonic_time(:millisecond) - start

    opts =
      Map.merge(meta, %{
        duration_ms: duration_ms,
        ttft_ms: ttft_ms,
        provider: used_provider.name(),
        metadata: Map.put(meta.metadata || %{}, "trace_id", request_id)
      })

    UsageTracking.track_usage(api_key, used_model, usage, opts)
    conn
  end

  defp pipe_stream(conn, stream, start, from_protocol, model, context) do
    usage = Usage.zero()

    Enum.reduce_while(stream, {conn, usage, nil}, fn %Event{} = event, {conn, usage, ttft} ->
      case Guardrails.on_stream_event(event, context) do
        {:ok, nil} ->
          {:cont, {conn, usage, ttft}}

        {:ok, %Event{} = event} ->
          usage = merge_stream_usage(usage, event)
          ttft = ttft || System.monotonic_time(:millisecond) - start

          write_stream_event(
            conn,
            usage,
            ttft,
            OpenAI.stream_event(event.data, from_protocol, model)
          )

        {:error, _reason} ->
          {:halt, {conn, usage, ttft}}
      end
    end)
    |> then(fn {conn, usage, ttft} ->
      {:ok, conn} = SSEWriter.write_done(conn)
      {conn, usage, ttft}
    end)
  end

  defp write_stream_event(conn, usage, ttft, nil), do: {:cont, {conn, usage, ttft}}

  defp write_stream_event(conn, usage, ttft, data) do
    case SSEWriter.write_event(conn, data) do
      {:ok, conn} -> {:cont, {conn, usage, ttft}}
      {:error, _reason} -> {:halt, {conn, usage, ttft}}
    end
  end

  defp stream_context(api_key, request, model, extra) do
    %{
      api_key: api_key,
      route: :chat,
      model: model,
      metadata: request.metadata || %{}
    }
    |> Map.merge(Map.new(extra))
  end

  defp provider_protocol(provider) do
    if function_exported?(provider, :native_protocol, 0),
      do: provider.native_protocol(),
      else: :openai
  end

  defp merge_stream_usage(usage, %{usage: event_usage}) when is_map(event_usage) do
    Usage.merge_max(usage, event_usage)
  end

  defp merge_stream_usage(usage, _), do: usage
end
