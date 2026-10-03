defmodule LLMProxy.Providers.OpenAICodex do
  @moduledoc """
  Adapter for the ChatGPT Codex backend exposed by ReqLLM.

  The provider uses LLMProxy's token pool for OAuth tokens and delegates Codex
  request construction, OAuth account handling, and WebSocket streaming to
  `ReqLLM.Providers.OpenAICodex`. It converts ReqLLM's canonical response and
  stream chunk structs back into the OpenAI-compatible wire shapes that LLMProxy
  HTTP routes expose.
  """

  @behaviour LLMProxy.Providers.Behaviour

  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.OpenAICodex.{Events, OAuth, ToolSchema}
  alias LLMProxy.Providers.ReqLLM.ErrorProjection
  alias LLMProxy.Providers.Result
  alias LLMProxy.Response, as: ProxyResponse
  alias LLMProxy.TokenPool.Server, as: TokenPool
  alias LLMProxy.Usage
  alias ReqLLM.Providers.OpenAICodex, as: ReqLLMOpenAICodex

  @impl true
  def name, do: "openai-codex"

  @impl true
  def native_protocol, do: :openai

  @impl true
  def models, do: LLMProxy.ModelDB.provider_model_ids(:openai_codex)

  @impl true
  def call(body, user_id) do
    with {:ok, request} <- request_from_chat_body(body),
         {:ok, token} <- pick_token(user_id, request.model),
         {:ok, response} <- generate(request, token, user_id, stream?: false) do
      {:ok,
       Result.response(
         ProxyResponse.to_openai_chat_completion(
           response,
           request.model,
           "chatcmpl-#{response.id}",
           response.usage,
           nil,
           System.system_time(:second)
         ),
         token
       )}
    end
  end

  @impl true
  def stream(body, user_id) do
    with {:ok, request} <- request_from_chat_body(body),
         {:ok, token} <- pick_token(user_id, request.model),
         {:ok, stream_response} <- generate(request, token, user_id, stream?: true) do
      {:ok,
       Result.stream(Events.openai_chat_events(stream_response.stream, request.model), token)}
    end
  end

  @impl true
  def call_native(body, user_id) do
    with {:ok, request} <- request_from_responses_body(body),
         {:ok, token} <- pick_token(user_id, request.model),
         {:ok, response} <- generate(request, token, user_id, stream?: false) do
      {:ok,
       Result.response(
         ProxyResponse.to_responses(response, request.model, System.system_time(:second)),
         token
       )}
    end
  end

  @impl true
  def stream_native(body, user_id) do
    with {:ok, request} <- request_from_responses_body(body),
         {:ok, token} <- pick_token(user_id, request.model),
         {:ok, stream_response} <- generate(request, token, user_id, stream?: true) do
      stream = Stream.map(stream_response.stream, &Events.responses_event/1)
      {:ok, Result.stream(Stream.reject(stream, &is_nil/1), token)}
    end
  end

  @impl true
  def stream_error(reason, token, _model) do
    result = ErrorProjection.result(reason, token)

    if ErrorProjection.codex_quota_exhausted?(reason) do
      %{
        result
        | status: 429,
          rate_limit_kind: :quota,
          rate_limit_scope: :account,
          replay_safety: :safe,
          retry_after_ms: ErrorProjection.quota_reset_delay(reason) || result.retry_after_ms
      }
    else
      result
    end
  end

  @impl true
  def extract_usage(%{"usage" => %{"input_tokens" => _} = usage}), do: Usage.from_responses(usage)

  def extract_usage(response), do: Usage.from_openai(response["usage"] || %{})

  @impl true
  def to_openai_response(response, model), do: Map.put(response, "model", model)

  @doc false
  def request_from_chat_body(body) when is_map(body) do
    case Request.parse(:openai_chat, body) do
      {:ok, %Request{} = request} -> {:ok, request}
      {:error, %Request.Error{} = error} -> provider_error(error.message, 400)
    end
  end

  def request_from_chat_body(_body), do: provider_error("Request must include messages", 400)

  @doc false
  def context_from_chat_body(body) do
    with {:ok, %Request{messages: messages}} <- request_from_chat_body(body) do
      {:ok, %ReqLLM.Context{messages: messages}}
    end
  end

  @doc false
  def request_from_responses_body(body) when is_map(body) do
    case Request.parse(:openai_responses, body) do
      {:ok, %Request{} = request} -> {:ok, request}
      {:error, %Request.Error{} = error} -> provider_error(error.message, 400)
    end
  end

  def request_from_responses_body(_body), do: provider_error("Request must include input", 400)

  @doc false
  def context_from_responses_body(body) do
    with {:ok, %Request{messages: messages}} <- request_from_responses_body(body) do
      {:ok, %ReqLLM.Context{messages: messages}}
    end
  end

  @doc false
  def req_llm_opts(token, stream?) do
    provider_options =
      [
        auth_mode: :oauth,
        access_token: token.token,
        codex_originator: "pi"
      ]
      |> maybe_put(:chatgpt_account_id, ReqLLMOpenAICodex.account_id_from_token(token.token))
      |> maybe_put(:openai_stream_transport, if(stream?, do: :websocket, else: :sse))

    timeout = LLMProxy.Config.provider_connect_timeout_ms()

    transport_opts =
      if stream? do
        [connect_timeout: timeout]
      else
        [
          req_http_options: [
            finch: [conn_opts: [transport_opts: [timeout: timeout]], pool_timeout: timeout]
          ]
        ]
      end

    [provider_options: provider_options, receive_timeout: :infinity] ++ transport_opts
  end

  @doc false
  def refresh_token_if_needed(
        token,
        refresh_fun \\ &ReqLLMOpenAICodex.refresh_oauth_credentials/2
      ) do
    OAuth.refresh_if_needed(token, refresh_fun)
  end

  defp pick_token(user_id, model) do
    case TokenPool.pick_token_by_kind(name(), "oauth", user_id, model) do
      {:ok, token} -> normalize_token_refresh(refresh_token_if_needed(token))
      {:error, _reason} -> provider_error("No available OpenAI Codex OAuth tokens", 503)
    end
  end

  defp normalize_token_refresh({:ok, token}), do: {:ok, token}

  defp normalize_token_refresh({:error, _reason}),
    do: provider_error("OpenAI Codex token refresh failed", 503)

  defp generate(%LLMProxy.Protocol.Request{} = request, token, user_id, stream?: false) do
    model_spec = "openai_codex:#{request.model}"
    context = %ReqLLM.Context{messages: request.messages}

    case ReqLLM.generate_text(
           model_spec,
           context,
           generation_opts(request, token, user_id, false)
         ) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, stream_error(reason, token, request.model)}
    end
  rescue
    _exception in [ArgumentError, RuntimeError] ->
      provider_error("OpenAI Codex request failed", 502)
  end

  defp generate(%LLMProxy.Protocol.Request{} = request, token, user_id, stream?: true) do
    model_spec = "openai_codex:#{request.model}"
    context = %ReqLLM.Context{messages: request.messages}

    case ReqLLM.stream_text(model_spec, context, generation_opts(request, token, user_id, true)) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, stream_error(reason, token, request.model)}
    end
  rescue
    _exception in [ArgumentError, RuntimeError] ->
      provider_error("OpenAI Codex request failed", 502)
  end

  @doc false
  def generation_opts(%Request{} = request, token, user_id, stream?) do
    token
    |> req_llm_opts(stream?)
    |> Keyword.update!(:provider_options, &session_options(&1, request, user_id))
    |> maybe_put(:tools, ToolSchema.strictify(request.tools))
    |> maybe_put(:tool_choice, request.tool_choice)
    |> maybe_put(:max_tokens, request.max_tokens)
    |> maybe_put(:reasoning_effort, request.reasoning_effort)
    |> maybe_put(:temperature, request.temperature)
    |> maybe_put(:top_p, request.top_p)
    |> maybe_put(:stop, request.stop)
    |> maybe_put(:parallel_tool_calls, request.body["parallel_tool_calls"])
  end

  defp session_options(options, request, user_id) do
    metadata = request.metadata || %{}
    cache_key = request.body["prompt_cache_key"] || metadata["session_id"]
    session_id = metadata["session_id"] || cache_key

    options
    |> maybe_put(:session_id, scoped_identity(user_id, session_id))
    |> maybe_put(:prompt_cache_key, scoped_identity(user_id, cache_key))
    |> maybe_put(:thread_id, scoped_identity(user_id, metadata["thread_id"]))
  end

  defp scoped_identity(user_id, identity) when is_binary(identity) and byte_size(identity) > 0 do
    :crypto.hash(:sha256, :erlang.term_to_binary({:llm_proxy_codex, user_id, identity}))
    |> Base.encode16(case: :lower)
  end

  defp scoped_identity(_user_id, _identity), do: nil

  defp maybe_put(list, _key, nil) when is_list(list), do: list
  defp maybe_put(list, key, value) when is_list(list), do: Keyword.put(list, key, value)

  defp provider_error(message, status), do: {:error, Result.error(message, status, nil)}
end
