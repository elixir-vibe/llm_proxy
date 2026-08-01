defmodule LLMProxy.Protocol.Request do
  @moduledoc """
  Boundary parser that normalizes OpenAI Chat, Anthropic Messages, and OpenAI Responses requests.
  """

  alias LLMProxy.Protocol.Request.Error
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall

  defstruct [
    :protocol,
    :model,
    :body,
    :stream,
    :metadata,
    :tags,
    :tools,
    :tool_choice,
    :max_tokens,
    :reasoning_effort,
    :temperature,
    :top_p,
    :stop,
    messages: []
  ]

  @type protocol :: :openai_chat | :anthropic_messages | :openai_responses
  @type t :: %__MODULE__{
          protocol: protocol(),
          model: String.t() | nil,
          body: map(),
          stream: boolean() | nil,
          metadata: map() | nil,
          tags: [String.t()] | nil,
          tools: [map()] | nil,
          tool_choice: term(),
          max_tokens: non_neg_integer() | nil,
          reasoning_effort: :none | :minimal | :low | :medium | :high | :xhigh | :max | nil,
          temperature: number() | nil,
          top_p: number() | nil,
          stop: [String.t()] | String.t() | nil,
          messages: [Message.t()]
        }

  @spec parse(protocol(), map()) :: {:ok, t()} | {:error, Error.t()}
  def parse(:openai_chat = protocol, %{"messages" => messages} = body) when is_list(messages) do
    build(protocol, body, messages, &openai_message/1)
  end

  def parse(:anthropic_messages = protocol, %{"messages" => messages} = body)
      when is_list(messages) do
    build(protocol, body, messages, &anthropic_message/1)
  end

  def parse(:openai_responses = protocol, %{"input" => input} = body) when is_list(input) do
    build(protocol, body, input, &responses_message/1)
  end

  def parse(_protocol, _body),
    do: error("missing_messages", "Request must include messages/input list")

  @spec native_body(t()) :: map()
  def native_body(%__MODULE__{body: body}), do: body

  @spec user_text(t()) :: String.t()
  def user_text(%__MODULE__{messages: messages}), do: last_user_text(messages)

  defp build(protocol, body, messages, parser) do
    with {:ok, parsed} <- parse_messages(messages, parser),
         {:ok, reasoning_effort} <- reasoning_effort(body) do
      {:ok,
       %__MODULE__{
         protocol: protocol,
         model: body["model"],
         body: body,
         stream: body["stream"],
         metadata: metadata(body),
         tags: tags(body),
         tools: body["tools"],
         tool_choice: normalize_tool_choice(protocol, body["tool_choice"]),
         max_tokens: body["max_tokens"],
         reasoning_effort: reasoning_effort,
         temperature: body["temperature"],
         top_p: body["top_p"],
         stop: body["stop"] || body["stop_sequences"],
         messages: parsed
       }}
    end
  end

  defp normalize_tool_choice(
         :openai_chat,
         %{"type" => "function", "function" => %{"name" => name}}
       )
       when is_binary(name),
       do: %{type: "tool", name: name}

  defp normalize_tool_choice(
         :openai_responses,
         %{"type" => "function", "name" => name}
       )
       when is_binary(name),
       do: %{type: "tool", name: name}

  defp normalize_tool_choice(
         :anthropic_messages,
         %{"type" => "tool", "name" => name}
       )
       when is_binary(name),
       do: %{type: "tool", name: name}

  defp normalize_tool_choice(_protocol, tool_choice), do: tool_choice

  @reasoning_efforts ~w(none minimal low medium high xhigh max)

  defp reasoning_effort(%{"reasoning_effort" => effort}), do: normalize_reasoning_effort(effort)

  defp reasoning_effort(%{"reasoning" => %{"effort" => effort}}),
    do: normalize_reasoning_effort(effort)

  defp reasoning_effort(_body), do: {:ok, nil}

  defp normalize_reasoning_effort(effort) when effort in @reasoning_efforts,
    do: {:ok, String.to_existing_atom(effort)}

  defp normalize_reasoning_effort(_effort),
    do: error("invalid_reasoning_effort", "Unsupported reasoning effort")

  defp metadata(%{"metadata" => %{} = metadata}), do: Map.delete(metadata, "tags")
  defp metadata(_body), do: nil

  defp tags(%{"metadata" => %{"tags" => tags}}) when is_list(tags), do: tags
  defp tags(_body), do: nil

  defp parse_messages(messages, parser) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, acc} ->
      case parser.(message) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp last_user_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(&1.role == :user))
    |> message_text()
  end

  defp message_text(nil), do: ""

  defp message_text(%Message{content: content}) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("\n", &(&1.text || ""))
  end

  defp openai_message(%{"role" => "user", "content" => content}) do
    with {:ok, parts} <- content_parts(content, :openai), do: {:ok, Context.user(parts)}
  end

  defp openai_message(%{"role" => "assistant", "content" => content} = message) do
    with {:ok, parts} <- content_parts(content, :openai),
         {:ok, tool_calls} <- tool_calls(message["tool_calls"]) do
      {:ok, Context.assistant(parts, tool_calls: tool_calls)}
    end
  end

  defp openai_message(%{"role" => "system", "content" => content}) do
    with {:ok, parts} <- content_parts(content, :openai), do: {:ok, Context.system(parts)}
  end

  defp openai_message(%{"role" => "tool", "tool_call_id" => id, "content" => content})
       when is_binary(id) do
    with {:ok, parts} <- content_parts(content, :openai),
         do: {:ok, Context.tool_result(id, parts)}
  end

  defp openai_message(_message), do: error("invalid_message", "Unsupported or malformed message")

  defp anthropic_message(%{"role" => "user", "content" => content}) do
    if tool_result_only?(content) do
      with {:ok, id} <- tool_result_id(content),
           {:ok, parts} <- tool_result_parts(content) do
        {:ok, Context.tool_result(id, parts)}
      end
    else
      with {:ok, parts} <- content_parts(content, :anthropic), do: {:ok, Context.user(parts)}
    end
  end

  defp anthropic_message(%{"role" => "assistant", "content" => content}) do
    with {:ok, parts} <- content_parts(content, :anthropic), do: {:ok, Context.assistant(parts)}
  end

  defp anthropic_message(message), do: openai_message(message)

  defp responses_message(%{"type" => "function_call_output"} = item) do
    {:ok, Context.tool_result(item["call_id"] || "", item["output"] || "")}
  end

  defp responses_message(%{"type" => "function_call"} = item) do
    with {:ok, tool_calls} <- responses_tool_calls(item) do
      {:ok, Context.assistant([], tool_calls: tool_calls, metadata: response_metadata(item))}
    end
  end

  defp responses_message(%{"role" => "system", "content" => content}) do
    with {:ok, parts} <- content_parts(content, :responses), do: {:ok, Context.system(parts)}
  end

  defp responses_message(%{"role" => "user", "content" => content}) do
    with {:ok, parts} <- content_parts(content, :responses), do: {:ok, Context.user(parts)}
  end

  defp responses_message(%{"role" => "assistant"} = item) do
    with {:ok, parts} <- content_parts(item["content"] || "", :responses),
         {:ok, tool_calls} <- responses_tool_calls(item) do
      {:ok, Context.assistant(parts, tool_calls: tool_calls, metadata: response_metadata(item))}
    end
  end

  defp responses_message(message), do: openai_message(message)

  defp content_parts(nil, _format), do: {:ok, []}
  defp content_parts("", _format), do: {:ok, []}
  defp content_parts(text, _format) when is_binary(text), do: {:ok, [ContentPart.text(text)]}

  defp content_parts(parts, format) when is_list(parts) do
    parts
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case content_part(part, format) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp content_parts(_content, _format),
    do: error("invalid_content", "Message content must be text or supported content parts")

  defp content_part(%{"type" => "text", "text" => text}, _format) when is_binary(text) do
    {:ok, ContentPart.text(text)}
  end

  defp content_part(%{"type" => type, "text" => text}, :responses)
       when type in ["input_text", "output_text"] and is_binary(text) do
    {:ok, ContentPart.text(text)}
  end

  defp content_part(%{"type" => "image_url", "image_url" => %{"url" => url} = image}, :openai)
       when is_binary(url) do
    {:ok, ContentPart.image_url(url, Map.take(image, ["detail"]))}
  end

  defp content_part(%{"type" => "input_image", "image_url" => url} = image, :responses)
       when is_binary(url) do
    {:ok, ContentPart.image_url(url, Map.take(image, ["detail"]))}
  end

  defp content_part(%{"type" => "input_file", "file_id" => file_id}, :responses)
       when is_binary(file_id) do
    {:ok, ContentPart.file_id(file_id)}
  end

  defp content_part(
         %{"type" => "input_file", "filename" => filename, "file_data" => file_data},
         :responses
       )
       when is_binary(filename) and is_binary(file_data) do
    {:ok,
     %ContentPart{
       type: :file,
       filename: filename,
       data: file_data,
       media_type: "application/octet-stream"
     }}
  end

  defp content_part(%{"type" => "thinking", "thinking" => text} = block, :anthropic)
       when is_binary(text) do
    {:ok, ContentPart.thinking(text, Map.take(block, ["signature"]))}
  end

  defp content_part(%{"type" => "redacted_thinking", "data" => data}, :anthropic)
       when is_binary(data) do
    {:ok, ContentPart.thinking("", %{"redacted" => true, "data" => data})}
  end

  defp content_part(
         %{"type" => "image", "source" => %{"type" => "url", "url" => url}},
         :anthropic
       )
       when is_binary(url) do
    {:ok, ContentPart.image_url(url)}
  end

  defp content_part(
         %{
           "type" => "image",
           "source" => %{"type" => "base64", "media_type" => media_type, "data" => data}
         },
         :anthropic
       )
       when is_binary(media_type) and is_binary(data) do
    {:ok, %ContentPart{type: :image, data: data, media_type: media_type}}
  end

  defp content_part(text, _format) when is_binary(text), do: {:ok, ContentPart.text(text)}
  defp content_part(_part, _format), do: error("invalid_content_part", "Unsupported content part")

  defp tool_calls(nil), do: {:ok, nil}

  defp tool_calls(calls) when is_list(calls) do
    calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, acc} ->
      case tool_call(call) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp tool_calls(_calls), do: error("invalid_tool_calls", "tool_calls must be a list")

  defp responses_tool_calls(%{"type" => "function_call"} = item) do
    {:ok,
     [
       ToolCall.new(
         item["call_id"] || item["id"],
         item["name"] || "unknown",
         arguments_json(item["arguments"])
       )
     ]}
  end

  defp responses_tool_calls(%{"tool_calls" => calls}), do: tool_calls(calls)
  defp responses_tool_calls(_item), do: {:ok, nil}

  defp tool_call(%{"id" => id, "function" => %{"name" => name, "arguments" => arguments}})
       when is_binary(name) and is_binary(arguments) do
    {:ok, ToolCall.new(id, name, arguments)}
  end

  defp tool_call(%{"function" => %{"name" => name, "arguments" => arguments}})
       when is_binary(name) and is_binary(arguments) do
    {:ok, ToolCall.new(nil, name, arguments)}
  end

  defp tool_call(%ToolCall{} = call), do: {:ok, call}
  defp tool_call(_call), do: error("invalid_tool_call", "Malformed tool call")

  defp response_metadata(%{"id" => id}) when is_binary(id), do: %{response_id: id}
  defp response_metadata(_item), do: %{}

  defp arguments_json(arguments) when is_binary(arguments), do: arguments
  defp arguments_json(arguments) when is_map(arguments), do: Jason.encode!(arguments)
  defp arguments_json(_arguments), do: "{}"

  defp tool_result_only?(content) when is_list(content) and content != [] do
    Enum.all?(content, &(&1["type"] == "tool_result"))
  end

  defp tool_result_only?(_content), do: false

  defp tool_result_id([%{"tool_use_id" => id} | _]) when is_binary(id), do: {:ok, id}

  defp tool_result_id(_content),
    do: error("invalid_tool_result", "Anthropic tool_result blocks require tool_use_id")

  defp tool_result_parts(content) do
    content
    |> Enum.reduce_while({:ok, []}, fn block, {:ok, acc} ->
      case content_parts(block["content"], :anthropic) do
        {:ok, parts} -> {:cont, {:ok, Enum.reverse(parts, acc)}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  defp error(code, message), do: {:error, Error.new(code, message)}
end
