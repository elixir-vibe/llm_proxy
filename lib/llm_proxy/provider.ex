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

  alias LLMProxy.Actor
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.{Caller, Registry, Result}
  alias LLMProxy.Response
  alias LLMProxy.Routes.Helpers
  alias LLMProxy.Routing.Attempt
  alias LLMProxy.Telemetry
  alias ReqLLM.Message.ContentPart

  @type call_error ::
          {:request, Request.Error.t()}
          | {:permission, String.t()}
          | {:not_found, String.t()}
          | {:missing_api_key, term()}
          | {:invalid_api_key, String.t()}
          | {:provider, Result.t()}

  @spec call(Request.t(), Actor.t() | map() | String.t(), keyword()) ::
          {:ok, Response.t()} | {:error, call_error()}
  def call(%Request{} = request, actor_or_key, opts \\ []) do
    route = Keyword.get(opts, :route, request.protocol)

    with {:ok, actor} <- normalize_actor(actor_or_key),
         {:ok, api_key} <- fetch_api_key(actor),
         :ok <- check_quota(actor, api_key),
         :ok <- Helpers.check_model_access(api_key, request.model),
         {:ok, [%Attempt{provider: provider, model: upstream_model} | _] = attempts} <-
           Registry.resolve_attempts(request.model) do
      Logger.debug(
        "Provider request from #{actor.name || actor.id} model=#{request.model} provider=#{provider.name()}"
      )

      Helpers.log_user_message(api_key, request.model, to_string(route), fn ->
        Request.user_text(request)
      end)

      call_provider(provider, request, api_key, upstream_model, attempts, opts)
    else
      :error -> {:error, {:not_found, "Model '#{request.model}' not found"}}
      {:error, {:missing_api_key, _}} = error -> error
      {:error, {:invalid_api_key, _}} = error -> error
      {:error, reason} when is_binary(reason) -> {:error, {:permission, reason}}
    end
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

  defp check_quota(%Actor{kind: :master}, _api_key), do: :ok
  defp check_quota(_actor, api_key), do: LLMProxy.Storage.check_quota(api_key)

  defp call_provider(provider, request, api_key, upstream_model, attempts, opts) do
    start = System.monotonic_time(:millisecond)

    trace_id = Keyword.get(opts, :trace_id) || LLMProxy.Trace.new_id()

    case Telemetry.with_provider_span(
           provider.name(),
           upstream_model,
           :call,
           fn -> Caller.call_attempts(attempts, request, api_key.id) end,
           %{"llm_proxy.trace_id" => trace_id}
         ) do
      {:ok, %Result{response: provider_body, provider: used_provider, model: used_model}} ->
        duration_ms = System.monotonic_time(:millisecond) - start
        usage = used_provider.extract_usage(provider_body)

        tracking_opts =
          %{
            duration_ms: duration_ms,
            provider: used_provider.name(),
            tags: request.tags,
            metadata: Map.put(request.metadata || %{}, "trace_id", trace_id)
          }
          |> Map.merge(Map.new(Keyword.get(opts, :usage_metadata, [])))

        Helpers.track_usage(api_key, used_model, usage, tracking_opts)

        Helpers.maybe_record_trace(
          api_key,
          used_model,
          request.body,
          provider_body,
          usage,
          tracking_opts
        )

        {:ok,
         %Response{
           body: used_provider.to_openai_response(provider_body, used_model),
           provider_body: provider_body,
           provider: used_provider,
           model: used_model,
           request: request,
           usage: usage,
           trace_id: trace_id
         }}

      {:error, %Result{} = result} ->
        {:error, {:provider, result}}
    end
  end

  defp run_req_llm(req_request) do
    request = Req.Request.get_private(req_request, :llm_proxy_request)
    opts = Req.Request.get_private(req_request, :llm_proxy_opts, [])
    actor = Keyword.get(opts, :llm_proxy_actor) || Keyword.get(opts, :actor)
    api_key = Keyword.get(opts, :llm_proxy_api_key) || Keyword.get(opts, :api_key)

    case call(request, actor || api_key, route: :req_llm) do
      {:ok, response} ->
        req_llm_response = to_req_llm_response(response)
        Req.Request.halt(req_request, Req.Response.new(status: 200, body: req_llm_response))

      {:error, reason} ->
        Req.Request.halt(
          req_request,
          Req.Response.new(status: error_status(reason), body: inspect(reason))
        )
    end
  end

  defp to_req_llm_response(%Response{} = response) do
    body = response.body
    text = response_text(body)

    %ReqLLM.Response{
      id: body["id"] || "llm_proxy",
      model: response.model,
      context: response.request.messages,
      message: ReqLLM.Context.assistant([ContentPart.text(text)]),
      object: body,
      stream?: false,
      stream: nil,
      usage: usage_map(response.usage),
      finish_reason: finish_reason(body),
      provider_meta: %{provider: response.provider.name()},
      error: nil
    }
  end

  defp model_id(%{model: model}) when is_binary(model), do: model
  defp model_id(%{id: id}) when is_binary(id), do: id
  defp model_id(model) when is_binary(model), do: model

  defp response_text(%{"choices" => [%{"message" => %{"content" => text}} | _]})
       when is_binary(text),
       do: text

  defp response_text(%{"output_text" => text}) when is_binary(text), do: text
  defp response_text(_body), do: ""

  defp finish_reason(%{"choices" => [%{"finish_reason" => "stop"} | _]}), do: :stop
  defp finish_reason(%{"choices" => [%{"finish_reason" => "length"} | _]}), do: :length
  defp finish_reason(%{"choices" => [%{"finish_reason" => "tool_calls"} | _]}), do: :tool_calls
  defp finish_reason(%{"choices" => [%{"finish_reason" => nil} | _]}), do: nil
  defp finish_reason(_body), do: nil

  defp usage_map(usage) do
    %{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      cache_read_tokens: usage.cache_read_tokens,
      cache_write_tokens: usage.cache_write_tokens
    }
  end

  defp error_status({:not_found, _}), do: 404
  defp error_status({:permission, _}), do: 403
  defp error_status({:missing_api_key, _}), do: 401
  defp error_status({:invalid_api_key, _}), do: 401
  defp error_status({:provider, %{status: status}}) when is_integer(status), do: status
  defp error_status(_reason), do: 500
end
