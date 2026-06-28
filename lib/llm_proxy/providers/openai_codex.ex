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
  alias LLMProxy.Providers.Result
  alias LLMProxy.Response, as: ProxyResponse
  alias LLMProxy.Stream.Event
  alias LLMProxy.TokenPool.Server, as: TokenPool
  alias LLMProxy.Usage
  alias ReqLLM.StreamChunk

  @impl true
  def name, do: "openai-codex"

  @impl true
  def native_protocol, do: :openai

  @impl true
  def models, do: LLMProxy.ModelDB.provider_model_ids(:openai_codex)

  @impl true
  def call(body, user_id) do
    with {:ok, token} <- pick_token(user_id),
         {:ok, context} <- context_from_chat_body(body),
         {:ok, response} <- generate(body["model"], context, token, stream?: false) do
      {:ok,
       Result.response(
         ProxyResponse.to_openai_chat_completion(
           response,
           body["model"],
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
    with {:ok, token} <- pick_token(user_id),
         {:ok, context} <- context_from_chat_body(body),
         {:ok, stream_response} <- generate(body["model"], context, token, stream?: true) do
      stream = Stream.map(stream_response.stream, &to_openai_chat_event(&1, body["model"]))
      {:ok, Result.stream(Stream.reject(stream, &is_nil/1), token)}
    end
  end

  @impl true
  def call_native(body, user_id) do
    with {:ok, token} <- pick_token(user_id),
         {:ok, context} <- context_from_responses_body(body),
         {:ok, response} <- generate(body["model"], context, token, stream?: false) do
      {:ok,
       Result.response(
         ProxyResponse.to_responses(response, body["model"], System.system_time(:second)),
         token
       )}
    end
  end

  @impl true
  def stream_native(body, user_id) do
    with {:ok, token} <- pick_token(user_id),
         {:ok, context} <- context_from_responses_body(body),
         {:ok, stream_response} <- generate(body["model"], context, token, stream?: true) do
      stream = Stream.map(stream_response.stream, &to_responses_event/1)
      {:ok, Result.stream(Stream.reject(stream, &is_nil/1), token)}
    end
  end

  @impl true
  def extract_usage(%{"usage" => %{"input_tokens" => _} = usage}), do: Usage.from_responses(usage)

  def extract_usage(response), do: Usage.from_openai(response["usage"] || %{})

  @impl true
  def to_openai_response(response, model), do: Map.put(response, "model", model)

  @doc false
  def context_from_chat_body(%{"messages" => messages}) when is_list(messages) do
    case ReqLLM.Context.normalize(messages) do
      {:ok, context} -> {:ok, context}
      {:error, reason} -> provider_error("Invalid chat messages: #{inspect(reason)}", 400)
    end
  end

  def context_from_chat_body(_body), do: provider_error("Request must include messages", 400)

  @doc false
  def context_from_responses_body(body) when is_map(body) do
    case Request.parse(:openai_responses, body) do
      {:ok, %Request{messages: messages}} -> {:ok, %ReqLLM.Context{messages: messages}}
      {:error, %Request.Error{} = error} -> provider_error(error.message, 400)
    end
  end

  def context_from_responses_body(_body), do: provider_error("Request must include input", 400)

  @doc false
  def req_llm_opts(token, stream?) do
    provider_options =
      [
        auth_mode: :oauth,
        access_token: token.token,
        codex_originator: "pi"
      ]
      |> maybe_put(:chatgpt_account_id, account_id_from_token(token.token))
      |> maybe_put(:openai_stream_transport, if(stream?, do: :websocket, else: :sse))

    [
      provider_options: provider_options,
      receive_timeout: LLMProxy.Config.provider_receive_timeout_ms()
    ]
  end

  @doc false
  def to_responses_event(%StreamChunk{type: :content, text: text}) when is_binary(text) do
    Event.responses_output_text_delta(text)
  end

  def to_responses_event(%StreamChunk{type: :thinking, text: text}) when is_binary(text) do
    Event.responses_reasoning_delta(text)
  end

  def to_responses_event(%StreamChunk{type: :tool_call} = chunk) do
    index = Map.get(chunk.metadata, :index, 0)
    id = Map.get(chunk.metadata, :id) || "call_#{System.unique_integer([:positive])}"

    Event.responses_function_call_added(index, id, chunk.name, chunk.arguments || %{})
  end

  def to_responses_event(%StreamChunk{type: :meta, metadata: metadata}) do
    if metadata[:terminal?] do
      Event.responses_terminal(
        metadata[:finish_reason],
        metadata[:response_id] || "resp_#{System.unique_integer([:positive])}",
        metadata[:usage]
      )
    end
  end

  def to_responses_event(_chunk), do: nil

  @doc false
  def to_openai_chat_event(%StreamChunk{type: :content, text: text}, model)
      when is_binary(text) do
    Event.openai_chat_content_delta(model, text)
  end

  def to_openai_chat_event(%StreamChunk{type: :tool_call} = chunk, model) do
    index = Map.get(chunk.metadata, :index, 0)
    id = Map.get(chunk.metadata, :id) || "call_#{System.unique_integer([:positive])}"

    Event.openai_chat_tool_call_delta(index, id, chunk.name, chunk.arguments || %{}, model)
  end

  def to_openai_chat_event(%StreamChunk{type: :meta, metadata: metadata}, model) do
    if metadata[:terminal?] do
      Event.openai_chat_terminal(model, metadata[:finish_reason], metadata[:usage])
    end
  end

  def to_openai_chat_event(_chunk, _model), do: nil

  defp pick_token(user_id) do
    case TokenPool.pick_token_by_kind(name(), "oauth", user_id) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> provider_error("No available OpenAI Codex OAuth tokens: #{reason}", 503)
    end
  end

  defp generate(model, %ReqLLM.Context{} = context, token, stream?: false) do
    model_spec = "openai_codex:#{model}"

    case ReqLLM.generate_text(model_spec, context, req_llm_opts(token, false)) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> provider_error(Exception.message(reason), 502)
    end
  rescue
    exception -> provider_error(Exception.message(exception), 502)
  end

  defp generate(model, %ReqLLM.Context{} = context, token, stream?: true) do
    model_spec = "openai_codex:#{model}"

    case ReqLLM.stream_text(model_spec, context, req_llm_opts(token, true)) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> provider_error(Exception.message(reason), 502)
    end
  rescue
    exception -> provider_error(Exception.message(exception), 502)
  end

  defp account_id_from_token(token), do: ReqLLM.Providers.OpenAICodex.account_id_from_token(token)

  defp maybe_put(list, _key, nil) when is_list(list), do: list
  defp maybe_put(list, key, value) when is_list(list), do: Keyword.put(list, key, value)

  defp provider_error(message, status), do: {:error, Result.error(message, status, nil)}
end
