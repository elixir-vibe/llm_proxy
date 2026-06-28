defmodule LLMProxy.Provider do
  @moduledoc """
  Core in-process LLMProxy provider and ReqLLM adapter.

  HTTP routes and local Elixir calls use this module as the execution boundary.
  The ReqLLM callbacks expose the same execution path through ReqLLM's provider API.
  """

  use ReqLLM.Provider,
    id: :llm_proxy,
    default_base_url: "in-process://llm_proxy"

  require Logger

  alias LLMProxy.Accounting.UsageTracking
  alias LLMProxy.Actor
  alias LLMProxy.Cache.Runtime, as: CacheRuntime
  alias LLMProxy.GuardrailPipeline
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.{Caller, Registry, Result}
  alias LLMProxy.Providers.Routing.Attempt
  alias LLMProxy.Response
  alias LLMProxy.Stream.Event
  alias LLMProxy.Telemetry
  alias LLMProxy.Usage
  alias ReqLLM.Provider.Defaults, as: ReqLLMDefaults

  @dialyzer {:nowarn_function, req_llm_response: 6}

  @type call_error ::
          {:request, Request.Error.t()}
          | {:permission, String.t()}
          | {:not_found, String.t()}
          | {:missing_api_key, term()}
          | {:invalid_api_key, String.t()}
          | {:guardrail, term()}
          | {:provider, Result.t()}

  @spec call(Request.t(), Actor.t() | map() | String.t(), keyword()) ::
          {:ok, Response.t()} | {:error, call_error()}
  def call(%Request{} = request, actor_or_key, opts \\ []) do
    route = Keyword.get(opts, :route, request.protocol)

    with {:ok, actor} <- normalize_actor(actor_or_key),
         {:ok, api_key} <- fetch_api_key(actor),
         :ok <- check_quota(actor, api_key),
         {:ok, request} <- guard_before_request(request, actor, api_key, route),
         :ok <- check_model_access(api_key, request.model),
         {:ok, [%Attempt{provider: provider, model: upstream_model} | _] = attempts} <-
           Registry.resolve_attempts(request.model) do
      Logger.debug(
        "Provider request from #{actor.name || actor.id} model=#{request.model} provider=#{provider.name()}"
      )

      UsageTracking.log_user_message(api_key, request.model, to_string(route), fn ->
        Request.user_text(request)
      end)

      call_provider(provider, request, actor, api_key, upstream_model, attempts, route, opts)
    else
      :error -> {:error, {:not_found, "Model '#{request.model}' not found"}}
      {:error, {:missing_api_key, _}} = error -> error
      {:error, {:invalid_api_key, _}} = error -> error
      {:error, {:guardrail, _reason}} = error -> error
      {:error, reason} when is_binary(reason) -> {:error, {:permission, reason}}
    end
  end

  @spec stream(Request.t(), Actor.t() | map() | String.t(), keyword()) ::
          {:ok, Result.t()} | {:error, call_error()}
  def stream(%Request{} = request, actor_or_key, opts \\ []) do
    route = Keyword.get(opts, :route, request.protocol)
    request = %{request | stream: true, body: Map.put(request.body, "stream", true)}

    with {:ok, actor} <- normalize_actor(actor_or_key),
         {:ok, api_key} <- fetch_api_key(actor),
         :ok <- check_quota(actor, api_key),
         {:ok, request} <- guard_before_request(request, actor, api_key, route),
         :ok <- check_model_access(api_key, request.model),
         {:ok, [%Attempt{provider: provider, model: upstream_model} | _] = attempts} <-
           Registry.resolve_attempts(request.model) do
      Logger.debug(
        "Provider stream from #{actor.name || actor.id} model=#{request.model} provider=#{provider.name()}"
      )

      UsageTracking.log_user_message(api_key, request.model, to_string(route), fn ->
        Request.user_text(request)
      end)

      stream_provider(provider, request, actor, api_key, upstream_model, attempts, route, opts)
    else
      :error -> {:error, {:not_found, "Model '#{request.model}' not found"}}
      {:error, {:missing_api_key, _}} = error -> error
      {:error, {:invalid_api_key, _}} = error -> error
      {:error, {:guardrail, _reason}} = error -> error
      {:error, reason} when is_binary(reason) -> {:error, {:permission, reason}}
    end
  end

  @spec call_native(Request.t(), Actor.t() | map() | String.t(), keyword()) ::
          {:ok, Result.t()} | {:error, call_error()}
  def call_native(%Request{} = request, actor_or_key, opts \\ []) do
    execute_native(request, actor_or_key, :call_native, opts)
  end

  @spec stream_native(Request.t(), Actor.t() | map() | String.t(), keyword()) ::
          {:ok, Result.t()} | {:error, call_error()}
  def stream_native(%Request{} = request, actor_or_key, opts \\ []) do
    request = %{request | stream: true, body: Map.put(request.body, "stream", true)}
    execute_native(request, actor_or_key, :stream_native, opts)
  end

  @spec chat(String.t() | list() | ReqLLM.Context.t(), keyword()) ::
          {:ok, Response.t()} | {:error, call_error() | {:request, Request.Error.t()}}
  def chat(messages, opts \\ []) do
    case chat_request(messages, opts) do
      {:ok, request} ->
        actor = Keyword.get(opts, :actor) || Keyword.fetch!(opts, :api_key)
        call(request, actor, Keyword.put(opts, :route, :chat))

      {:error, %Request.Error{} = error} ->
        {:error, {:request, error}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec chat_request(String.t() | list() | ReqLLM.Context.t(), keyword()) ::
          {:ok, Request.t()} | {:error, Request.Error.t() | term()}
  def chat_request(messages, opts) do
    with {:ok, context} <- ReqLLM.Context.normalize(messages, opts) do
      request_from_context(context, opts)
    end
  end

  @impl ReqLLM.Provider
  def prepare_request(:chat, model, messages, opts) do
    with {:ok, context} <- ReqLLM.Context.normalize(messages, opts),
         {:ok, request} <- chat_request(context, Keyword.put(opts, :model, model_id(model))) do
      req =
        Req.new()
        |> Req.Request.prepend_request_steps(llm_proxy_provider: &run_req_llm/1)
        |> Req.Request.put_private(:llm_proxy_request, request)
        |> Req.Request.put_private(:llm_proxy_opts, opts)

      {:ok, req}
    end
  end

  def prepare_request(operation, _model, _data, _opts) do
    {:error, ArgumentError.exception("LLMProxy ReqLLM provider does not support #{operation}")}
  end

  @impl ReqLLM.Provider
  def attach(request, _model, _opts), do: request

  @impl ReqLLM.Provider
  def encode_body(request), do: request

  @impl ReqLLM.Provider
  def build_body(_request), do: %{}

  @impl ReqLLM.Provider
  def decode_response(request_response), do: request_response

  defp model_id(%{model: model}) when is_binary(model), do: model
  defp model_id(%{id: id}) when is_binary(id), do: id
  defp model_id(model) when is_binary(model), do: model

  defp request_from_context(%ReqLLM.Context{messages: messages}, opts) do
    model = Keyword.fetch!(opts, :model)

    {:ok,
     %Request{
       protocol: :openai_chat,
       model: model,
       body: request_body(messages, opts),
       stream: Keyword.get(opts, :stream, false),
       metadata: Keyword.get(opts, :metadata),
       tags: Keyword.get(opts, :tags),
       tools: Keyword.get(opts, :tools),
       tool_choice: Keyword.get(opts, :tool_choice),
       max_tokens: Keyword.get(opts, :max_tokens),
       temperature: Keyword.get(opts, :temperature),
       top_p: Keyword.get(opts, :top_p),
       stop: Keyword.get(opts, :stop),
       messages: messages
     }}
  rescue
    error in KeyError -> {:error, error}
  end

  defp request_body(messages, opts) do
    %{"model" => Keyword.fetch!(opts, :model), "messages" => messages}
    |> put_if_present("stream", Keyword.get(opts, :stream))
    |> put_if_present("metadata", Keyword.get(opts, :metadata))
    |> put_if_present("tools", Keyword.get(opts, :tools))
    |> put_if_present("tool_choice", Keyword.get(opts, :tool_choice))
    |> put_if_present("max_tokens", Keyword.get(opts, :max_tokens))
    |> put_if_present("temperature", Keyword.get(opts, :temperature))
    |> put_if_present("top_p", Keyword.get(opts, :top_p))
    |> put_if_present("stop", Keyword.get(opts, :stop))
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp normalize_actor(%Actor{} = actor), do: {:ok, actor}
  defp normalize_actor(%{id: _id} = api_key), do: {:ok, Actor.from_api_key(api_key)}

  defp normalize_actor(raw_key) when is_binary(raw_key) do
    cond do
      LLMProxy.Config.valid_master_key?(raw_key) ->
        {:ok, Actor.from_api_key(Actor.master_key())}

      api_key = LLMProxy.Storage.find_key(raw_key) ->
        {:ok, Actor.from_api_key(api_key)}

      true ->
        {:error, {:invalid_api_key, raw_key}}
    end
  end

  defp normalize_actor(nil), do: {:error, {:missing_api_key, nil}}

  defp fetch_api_key(%Actor{api_key: %{id: _id} = api_key}), do: {:ok, api_key}
  defp fetch_api_key(%Actor{} = actor), do: {:error, {:missing_api_key, actor}}

  defp guard_before_request(request, actor, api_key, route) do
    context = guard_context(request, actor, api_key, route)

    case GuardrailPipeline.before_request(request, context) do
      {:ok, request} -> {:ok, request}
      {:error, reason} -> {:error, {:guardrail, reason}}
    end
  end

  defp guard_context(request, actor, api_key, route, extra \\ %{}) do
    Map.merge(
      %{
        actor: actor,
        api_key: api_key,
        route: route,
        model: request.model,
        metadata: request.metadata || %{}
      },
      extra
    )
  end

  defp check_quota(%Actor{kind: :master}, _api_key), do: :ok
  defp check_quota(_actor, api_key), do: LLMProxy.Storage.check_quota(api_key)

  defp check_model_access(%{id: "master"}, _model), do: :ok
  defp check_model_access(api_key, model), do: LLMProxy.Storage.check_model_access(api_key, model)

  defp call_provider(provider, request, actor, api_key, upstream_model, attempts, route, opts) do
    start = System.monotonic_time(:millisecond)

    trace_id = Keyword.get(opts, :trace_id) || LLMProxy.Trace.new_id()
    cache_key = CacheRuntime.key(request, attempts)

    context =
      guard_context(request, actor, api_key, route, %{
        provider: provider,
        model: upstream_model,
        trace_id: trace_id,
        cache_key: cache_key
      })

    with :miss <- cache_get(cache_key, request, context),
         {:ok, result} <-
           call_provider_attempts(provider, upstream_model, attempts, request, api_key, trace_id) do
      handle_provider_result(result, request, api_key, context, start, cache_key, opts)
    else
      {:hit, %Response{} = response} -> {:ok, response}
      {:error, %Result{} = result} -> {:error, {:provider, result}}
      {:error, {:guardrail, _reason}} = error -> error
    end
  end

  defp cache_get(cache_key, request, context) do
    if CacheRuntime.enabled?(request, context) do
      case CacheRuntime.get(cache_key, context) do
        {:hit, %Response{} = response} ->
          {:hit, %{response | request: request, trace_id: context.trace_id, cache_hit: true}}

        :miss ->
          :miss
      end
    else
      :miss
    end
  end

  defp call_provider_attempts(provider, upstream_model, attempts, request, api_key, trace_id) do
    Telemetry.with_provider_span(
      provider.name(),
      upstream_model,
      :call,
      fn -> Caller.call_attempts(attempts, request, api_key.id) end,
      %{"llm_proxy.trace_id" => trace_id}
    )
  end

  defp execute_native(%Request{} = request, actor_or_key, function, opts) do
    route = Keyword.get(opts, :route, request.protocol)

    with {:ok, actor} <- normalize_actor(actor_or_key),
         {:ok, api_key} <- fetch_api_key(actor),
         :ok <- check_quota(actor, api_key),
         {:ok, request} <- guard_before_request(request, actor, api_key, route),
         :ok <- check_model_access(api_key, request.model),
         {:ok, [%Attempt{provider: provider, model: upstream_model} | _] = attempts} <-
           Registry.resolve_attempts(request.model) do
      Logger.debug(
        "Provider native #{function} from #{actor.name || actor.id} model=#{request.model} provider=#{provider.name()}"
      )

      UsageTracking.log_user_message(api_key, request.model, to_string(route), fn ->
        Request.user_text(request)
      end)

      call_native_provider(provider, upstream_model, attempts, request, api_key, function, opts)
    else
      :error -> {:error, {:not_found, "Model '#{request.model}' not found"}}
      {:error, {:missing_api_key, _}} = error -> error
      {:error, {:invalid_api_key, _}} = error -> error
      {:error, {:guardrail, _reason}} = error -> error
      {:error, reason} when is_binary(reason) -> {:error, {:permission, reason}}
    end
  end

  defp call_native_provider(provider, upstream_model, attempts, request, api_key, function, opts) do
    trace_id = Keyword.get(opts, :trace_id) || LLMProxy.Trace.new_id()
    api_name = Keyword.get(opts, :api_name, native_api_name(request.protocol))

    result =
      Telemetry.with_provider_span(
        provider.name(),
        upstream_model,
        function,
        fn -> invoke_native(function, attempts, request, api_key.id, api_name) end,
        %{"llm_proxy.trace_id" => trace_id}
      )

    case result do
      {:ok, %Result{} = result} -> {:ok, result}
      {:error, %Result{} = result} -> {:error, {:provider, result}}
    end
  end

  defp invoke_native(:call_native, attempts, request, user_id, api_name) do
    Caller.call_native_attempts(attempts, request, user_id, api_name)
  end

  defp invoke_native(:stream_native, attempts, request, user_id, api_name) do
    Caller.stream_native_attempts(attempts, request, user_id, api_name)
  end

  defp native_api_name(:anthropic_messages), do: "Messages API"
  defp native_api_name(:openai_responses), do: "Responses API"
  defp native_api_name(_protocol), do: "native API"

  defp stream_provider(provider, request, actor, api_key, upstream_model, attempts, route, opts) do
    start = System.monotonic_time(:millisecond)
    trace_id = Keyword.get(opts, :trace_id) || LLMProxy.Trace.new_id()

    context =
      guard_context(request, actor, api_key, route, %{
        provider: provider,
        model: upstream_model,
        trace_id: trace_id
      })

    case stream_provider_attempts(provider, upstream_model, attempts, request, api_key, trace_id) do
      {:ok,
       %Result{kind: :stream, stream: stream, provider: used_provider, model: used_model} = result} ->
        context = %{context | provider: used_provider, model: used_model}
        stream = track_stream(stream, used_model, request, api_key, context, start, opts)
        {:ok, %{result | stream: stream}}

      {:error, %Result{} = result} ->
        {:error, {:provider, result}}
    end
  end

  defp stream_provider_attempts(provider, upstream_model, attempts, request, api_key, trace_id) do
    Telemetry.with_provider_span(
      provider.name(),
      upstream_model,
      :stream,
      fn -> Caller.stream_attempts(attempts, request, api_key.id) end,
      %{"llm_proxy.trace_id" => trace_id}
    )
  end

  defp track_stream(stream, model, request, api_key, context, start, opts) do
    Stream.transform(
      stream,
      fn -> {Usage.zero(), nil} end,
      fn %Event{} = event, {usage, ttft_ms} ->
        case GuardrailPipeline.on_stream_event(event, context) do
          {:ok, nil} ->
            {[], {usage, ttft_ms}}

          {:ok, %Event{} = event} ->
            usage = merge_stream_usage(usage, event)
            ttft_ms = ttft_ms || System.monotonic_time(:millisecond) - start
            {[event], {usage, ttft_ms}}

          {:error, _reason} ->
            {:halt, {usage, ttft_ms}}
        end
      end,
      fn {usage, ttft_ms} = acc ->
        duration_ms = System.monotonic_time(:millisecond) - start
        track_stream_response(api_key, model, request, usage, duration_ms, ttft_ms, context, opts)
        {[], acc}
      end,
      fn _acc -> :ok end
    )
  end

  defp merge_stream_usage(usage, %Event{usage: event_usage}) when not is_nil(event_usage) do
    Usage.merge_max(usage, event_usage)
  end

  defp merge_stream_usage(usage, _event), do: usage

  defp track_stream_response(api_key, model, request, usage, duration_ms, ttft_ms, context, opts) do
    usage_metadata = Map.new(Keyword.get(opts, :usage_metadata, []))

    tracking_opts = %{
      duration_ms: duration_ms,
      ttft_ms: ttft_ms,
      provider: context.provider.name(),
      tags: Map.get(usage_metadata, :tags, request.tags),
      metadata: tracking_metadata(request, usage_metadata, context.trace_id)
    }

    UsageTracking.track_usage(api_key, model, usage, tracking_opts)
  end

  defp handle_provider_result(
         %Result{
           kind: :response,
           response: provider_body,
           provider: used_provider,
           model: used_model
         },
         request,
         api_key,
         context,
         start,
         cache_key,
         opts
       ) do
    duration_ms = System.monotonic_time(:millisecond) - start
    usage = used_provider.extract_usage(provider_body)

    cache_policy = CacheRuntime.policy(request, context)

    openai_body = used_provider.to_openai_response(provider_body, used_model)

    response = %Response{
      message:
        req_llm_response(openai_body, used_model, request, used_provider, context.trace_id, usage),
      provider_response: provider_body,
      provider: used_provider,
      model: used_model,
      request: request,
      usage: usage,
      trace_id: context.trace_id,
      cache_ttl_ms: cache_policy.ttl_ms
    }

    context = %{context | provider: used_provider, model: used_model}

    case GuardrailPipeline.after_response(response, context) do
      {:ok, response} ->
        CacheRuntime.put(cache_key, request, response, context)
        track_provider_response(api_key, used_model, request, response, duration_ms, opts)
        {:ok, response}

      {:error, reason} ->
        {:error, {:guardrail, reason}}
    end
  end

  defp track_provider_response(api_key, model, request, response, duration_ms, opts) do
    usage_metadata = Map.new(Keyword.get(opts, :usage_metadata, []))

    tracking_opts = %{
      duration_ms: duration_ms,
      provider: response.provider.name(),
      tags: Map.get(usage_metadata, :tags, request.tags),
      metadata: tracking_metadata(request, usage_metadata, response.trace_id)
    }

    UsageTracking.track_usage(api_key, model, response.usage, tracking_opts)

    UsageTracking.maybe_record_trace(
      api_key,
      model,
      request.body,
      response.provider_response,
      response.usage,
      tracking_opts
    )
  end

  defp tracking_metadata(request, usage_metadata, trace_id) do
    request.metadata
    |> Kernel.||(%{})
    |> Map.merge(Map.get(usage_metadata, :metadata) || %{})
    |> Map.put("trace_id", trace_id)
  end

  defp run_req_llm(req_request) do
    request = Req.Request.get_private(req_request, :llm_proxy_request)
    opts = Req.Request.get_private(req_request, :llm_proxy_opts, [])
    actor = Keyword.get(opts, :llm_proxy_actor) || Keyword.get(opts, :actor)
    api_key = Keyword.get(opts, :llm_proxy_api_key) || Keyword.get(opts, :api_key)

    result =
      case Keyword.get(opts, :safe_rpc) || Keyword.get(opts, :llm_proxy_socket) do
        nil ->
          call(request, actor || api_key, route: :req_llm)

        socket_or_client ->
          SafeRPC.call(socket_or_client, {LLMProxy, :chat}, request,
            meta: req_llm_safe_rpc_meta(actor, api_key),
            timeout: Keyword.get(opts, :safe_rpc_timeout, LLMProxy.Config.remote_timeout_ms())
          )
      end

    case result do
      {:ok, response} ->
        Req.Request.halt(
          req_request,
          Req.Response.new(status: 200, body: req_llm_response(response))
        )

      {:error, reason} ->
        Req.Request.halt(
          req_request,
          Req.Response.new(status: error_status(reason), body: inspect(reason))
        )
    end
  end

  defp req_llm_response(%Response{message: %ReqLLM.Response{} = message}), do: message

  defp req_llm_response(openai_body, model_id, request, provider, trace_id, usage) do
    model = LLMDB.Model.new!(%{id: model_id, provider: :llm_proxy})

    {:ok, req_llm_response} =
      ReqLLMDefaults.decode_response_body_openai_format(openai_body, model)

    %{
      req_llm_response
      | context: %ReqLLM.Context{messages: request.messages},
        usage: req_llm_usage(usage),
        provider_meta:
          Map.merge(req_llm_response.provider_meta, %{
            provider: provider.name(),
            trace_id: trace_id
          })
    }
  end

  defp req_llm_usage(%Usage{} = usage) do
    %{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      cache_read_tokens: usage.cache_read_tokens,
      cache_write_tokens: usage.cache_write_tokens,
      total_tokens: usage.input_tokens + usage.output_tokens
    }
  end

  defp error_status({:not_found, _}), do: 404
  defp error_status({:permission, _}), do: 403
  defp error_status({:missing_api_key, _}), do: 401
  defp error_status({:invalid_api_key, _}), do: 401
  defp error_status({:guardrail, _}), do: 403
  defp error_status({:provider, %{status: status}}) when is_integer(status), do: status
  defp error_status(_reason), do: 500

  defp req_llm_safe_rpc_meta(actor, api_key) do
    %{}
    |> put_if_present(:actor, actor)
    |> put_if_present(:api_key, api_key)
  end
end
