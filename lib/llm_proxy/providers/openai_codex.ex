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

  alias LLMProxy.Providers.Result
  alias LLMProxy.Response, as: ProxyResponse
  alias LLMProxy.Stream.Event
  alias LLMProxy.TokenPool.Server, as: TokenPool
  alias LLMProxy.Usage
  alias ReqLLM.Message.ContentPart
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
      {:ok, Result.response(to_responses_response(response, body["model"]), token)}
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
  def context_from_responses_body(%{"input" => input}) when is_list(input) do
    {:ok, ReqLLM.Context.new(Enum.flat_map(input, &responses_item_to_messages/1))}
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
    Event.new(%{"type" => "response.output_text.delta", "delta" => text})
  end

  def to_responses_event(%StreamChunk{type: :thinking, text: text}) when is_binary(text) do
    Event.new(%{"type" => "response.reasoning.delta", "delta" => text})
  end

  def to_responses_event(%StreamChunk{type: :tool_call} = chunk) do
    index = Map.get(chunk.metadata, :index, 0)
    id = Map.get(chunk.metadata, :id) || "call_#{System.unique_integer([:positive])}"

    Event.new(%{
      "type" => "response.output_item.added",
      "output_index" => index,
      "item" => %{
        "type" => "function_call",
        "id" => id,
        "call_id" => id,
        "name" => chunk.name,
        "arguments" => Jason.encode!(chunk.arguments || %{})
      }
    })
  end

  def to_responses_event(%StreamChunk{type: :meta, metadata: metadata}) do
    if metadata[:terminal?] do
      usage = Usage.to_responses(metadata[:usage])

      Event.new(
        %{
          "type" => terminal_type(metadata[:finish_reason]),
          "response" => %{
            "id" => metadata[:response_id] || "resp_#{System.unique_integer([:positive])}",
            "status" => response_status(metadata[:finish_reason]),
            "usage" => usage
          }
        },
        usage: Usage.from_responses(usage)
      )
    end
  end

  def to_responses_event(_chunk), do: nil

  @doc false
  def to_openai_chat_event(%StreamChunk{type: :content, text: text}, model)
      when is_binary(text) do
    Event.new(openai_chunk(model, %{"content" => text}, nil))
  end

  def to_openai_chat_event(%StreamChunk{type: :tool_call} = chunk, model) do
    index = Map.get(chunk.metadata, :index, 0)
    id = Map.get(chunk.metadata, :id) || "call_#{System.unique_integer([:positive])}"

    delta = %{
      "tool_calls" => [
        %{
          "index" => index,
          "id" => id,
          "type" => "function",
          "function" => %{
            "name" => chunk.name,
            "arguments" => Jason.encode!(chunk.arguments || %{})
          }
        }
      ]
    }

    Event.new(openai_chunk(model, delta, nil))
  end

  def to_openai_chat_event(%StreamChunk{type: :meta, metadata: metadata}, model) do
    if metadata[:terminal?] do
      usage = Usage.to_openai(metadata[:usage])

      event =
        Event.new(openai_chunk(model, %{}, chat_finish_reason(metadata[:finish_reason]), usage))

      Event.attach_usage(event, Usage.from_openai(usage))
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

  defp responses_item_to_messages(%{"type" => "function_call_output"} = item) do
    [ReqLLM.Context.tool_result(item["call_id"] || "", item["output"] || "")]
  end

  defp responses_item_to_messages(%{"role" => "system", "content" => content}) do
    [ReqLLM.Context.system(content_text(content))]
  end

  defp responses_item_to_messages(%{"role" => "user", "content" => content}) do
    [ReqLLM.Context.user(content_parts(content))]
  end

  defp responses_item_to_messages(%{"role" => "assistant"} = item) do
    content = content_parts(item["content"] || "")
    tool_calls = tool_calls_from_item(item)
    [ReqLLM.Context.assistant(content, tool_calls: tool_calls, metadata: response_metadata(item))]
  end

  defp responses_item_to_messages(_item), do: []

  defp content_parts(content) when is_binary(content), do: [ContentPart.text(content)]

  defp content_parts(content) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => type, "text" => text} when type in ["text", "input_text", "output_text"] ->
        [ContentPart.text(text || "")]

      %{"type" => "input_image", "image_url" => url} when is_binary(url) ->
        [%ContentPart{type: :image_url, url: url}]

      %{"type" => "image_url", "image_url" => %{"url" => url}} when is_binary(url) ->
        [%ContentPart{type: :image_url, url: url}]

      _other ->
        []
    end)
  end

  defp content_parts(_content), do: []

  defp content_text(content) do
    content
    |> content_parts()
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", &(&1.text || ""))
  end

  defp tool_calls_from_item(%{"type" => "function_call"} = item) do
    [
      {item["name"] || "unknown", arguments_map(item["arguments"]),
       id: item["call_id"] || item["id"]}
    ]
  end

  defp tool_calls_from_item(%{"tool_calls" => calls}) when is_list(calls) do
    Enum.map(calls, fn call ->
      function = call["function"] || %{}
      {function["name"] || "unknown", arguments_map(function["arguments"]), id: call["id"]}
    end)
  end

  defp tool_calls_from_item(_item), do: nil

  defp response_metadata(%{"id" => id}) when is_binary(id), do: %{response_id: id}
  defp response_metadata(_item), do: %{}

  defp arguments_map(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp arguments_map(arguments) when is_map(arguments), do: arguments
  defp arguments_map(_arguments), do: %{}

  defp to_responses_response(%ReqLLM.Response{} = response, model) do
    output = []
    text = ReqLLM.Response.text(response) || ""
    tool_calls = ReqLLM.Response.tool_calls(response)

    output =
      if text == "" do
        output
      else
        output ++
          [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}],
              "status" => "completed"
            }
          ]
      end

    output = output ++ Enum.map(tool_calls, &to_responses_tool_call/1)
    usage = Usage.to_responses(response.usage)

    %{
      "id" => response.id,
      "object" => "response",
      "created_at" => System.system_time(:second),
      "model" => model,
      "status" => response_status(response.finish_reason),
      "output" => output,
      "usage" => usage
    }
  end

  defp to_responses_tool_call(tool_call) do
    %{
      "type" => "function_call",
      "id" => tool_call.id,
      "call_id" => tool_call.id,
      "name" => ReqLLM.ToolCall.name(tool_call),
      "arguments" => ReqLLM.ToolCall.args_json(tool_call)
    }
  end

  defp account_id_from_token(token), do: ReqLLM.Providers.OpenAICodex.account_id_from_token(token)

  defp openai_chunk(model, delta, finish_reason, usage \\ nil) do
    chunk = %{
      "id" => "chatcmpl-#{System.unique_integer([:positive])}",
      "object" => "chat.completion.chunk",
      "created" => System.system_time(:second),
      "model" => model,
      "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish_reason}]
    }

    if usage, do: Map.put(chunk, "usage", usage), else: chunk
  end

  defp terminal_type(:incomplete), do: "response.incomplete"
  defp terminal_type(_reason), do: "response.completed"

  defp response_status(:incomplete), do: "incomplete"
  defp response_status(_reason), do: "completed"

  defp chat_finish_reason(:tool_calls), do: "tool_calls"
  defp chat_finish_reason(:length), do: "length"
  defp chat_finish_reason(:incomplete), do: "length"
  defp chat_finish_reason(_reason), do: "stop"

  defp maybe_put(list, _key, nil) when is_list(list), do: list
  defp maybe_put(list, key, value) when is_list(list), do: Keyword.put(list, key, value)

  defp provider_error(message, status), do: {:error, Result.error(message, status, nil)}
end
