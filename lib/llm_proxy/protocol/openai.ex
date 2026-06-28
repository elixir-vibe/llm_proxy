defmodule LLMProxy.Protocol.OpenAI do
  @moduledoc """
  OpenAI chat completion protocol.

  Handles conversion between OpenAI format and other protocols.
  """

  @behaviour LLMProxy.Protocol

  alias LLMProxy.Protocol.Request
  alias LLMProxy.Usage
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Provider.Defaults, as: ReqLLMDefaults
  alias ReqLLM.ToolCall

  @impl true
  def protocol, do: :openai

  @spec request_body(Request.t()) :: map()
  def request_body(%Request{} = request) do
    %ReqLLM.Context{messages: request.messages}
    |> ReqLLMDefaults.encode_context_to_openai_format(request.model)
    |> normalize_openai_messages(request.messages)
    |> stringify_keys()
    |> Map.merge(Map.take(request.body, ["parallel_tool_calls", "response_format"]))
    |> Map.put("model", request.model)
    |> maybe_put("stream", request.stream)
    |> maybe_put("tools", request.tools)
    |> maybe_put("tool_choice", request.tool_choice)
    |> maybe_put("max_tokens", request.max_tokens)
    |> maybe_put("temperature", request.temperature)
    |> maybe_put("top_p", request.top_p)
    |> maybe_put("stop", request.stop)
  end

  @impl true
  def convert_response(response, :openai, model) do
    Map.put(response, "model", model)
  end

  def convert_response(response, :anthropic, model) do
    anthropic_to_openai_response(response, model)
  end

  def stream_event(event, :openai, _model), do: event
  def stream_event(event, :anthropic, model), do: anthropic_stream_event(event, model)

  @impl true
  def extract_usage(response) do
    response
    |> Map.get("usage", %{})
    |> Usage.from_openai()
  end

  defp normalize_openai_messages(%{messages: encoded_messages} = body, source_messages) do
    messages =
      encoded_messages
      |> Enum.zip(source_messages)
      |> Enum.map(fn {encoded, source} -> normalize_openai_message(encoded, source) end)

    %{body | messages: messages}
  end

  defp normalize_openai_message(encoded, source) do
    encoded
    |> normalize_tool_calls(source)
    |> normalize_content(source.content)
  end

  defp normalize_tool_calls(encoded, %{tool_calls: tool_calls}) when is_list(tool_calls) do
    Map.put(encoded, :tool_calls, Enum.map(tool_calls, &openai_tool_call/1))
  end

  defp normalize_tool_calls(encoded, _source), do: encoded

  defp openai_tool_call(%ToolCall{id: id, type: type, function: function}) do
    %{
      id: id,
      type: type,
      function: %{
        name: function.name,
        arguments: function.arguments
      }
    }
  end

  defp openai_tool_call(tool_call), do: tool_call

  defp normalize_content(encoded, source_content) when is_list(source_content) do
    case {Map.get(encoded, :content), source_content} do
      {encoded_content, source_content} when is_list(encoded_content) ->
        Map.put(encoded, :content, normalize_content_parts(encoded_content, source_content))

      {"", [%ContentPart{type: :file, metadata: %{"file_id" => _file_id}}]} ->
        Map.put(encoded, :content, normalize_content_parts([], source_content))

      _other ->
        encoded
    end
  end

  defp normalize_content(encoded, _source_content), do: encoded

  defp normalize_content_parts(encoded_parts, source_parts) do
    source_parts
    |> zip_longest(encoded_parts)
    |> Enum.flat_map(fn
      {%ContentPart{type: :file, metadata: %{"file_id" => file_id}}, _encoded_part} ->
        [%{type: "file", file: %{file_id: file_id}}]

      {%ContentPart{type: :image_url, metadata: metadata}, %{image_url: image_url} = encoded_part} ->
        [%{encoded_part | image_url: maybe_put(image_url, :detail, metadata["detail"])}]

      {_source_part, nil} ->
        []

      {_source_part, encoded_part} ->
        [encoded_part]
    end)
  end

  defp zip_longest([], []), do: []
  defp zip_longest([left | left_rest], []), do: [{left, nil} | zip_longest(left_rest, [])]
  defp zip_longest([], [right | right_rest]), do: [{nil, right} | zip_longest([], right_rest)]

  defp zip_longest([left | left_rest], [right | right_rest]) do
    [{left, right} | zip_longest(left_rest, right_rest)]
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {string_key(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value), do: value

  defp string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp string_key(key), do: key

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp anthropic_stream_event(%{"type" => "message_start", "message" => message}, model) do
    chunk(message["id"], model, %{"role" => "assistant"})
  end

  defp anthropic_stream_event(
         %{"type" => "content_block_start", "index" => index, "content_block" => block},
         model
       ) do
    case block["type"] do
      "text" ->
        chunk(nil, model, %{"content" => block["text"] || ""})

      "tool_use" ->
        chunk(nil, model, %{
          "tool_calls" => [
            %{
              "index" => index,
              "id" => block["id"],
              "type" => "function",
              "function" => %{"name" => block["name"], "arguments" => ""}
            }
          ]
        })

      _ ->
        nil
    end
  end

  defp anthropic_stream_event(
         %{"type" => "content_block_delta", "index" => index, "delta" => delta},
         model
       ) do
    case delta["type"] do
      "text_delta" ->
        chunk(nil, model, %{"content" => delta["text"] || ""})

      "input_json_delta" ->
        chunk(nil, model, %{
          "tool_calls" => [
            %{"index" => index, "function" => %{"arguments" => delta["partial_json"] || ""}}
          ]
        })

      _ ->
        nil
    end
  end

  defp anthropic_stream_event(%{"type" => "message_delta", "delta" => delta}, model) do
    chunk(nil, model, %{}, map_stop_reason(delta["stop_reason"]))
  end

  defp anthropic_stream_event(%{"type" => "message_stop"}, _model), do: nil
  defp anthropic_stream_event(%{"type" => "content_block_stop"}, _model), do: nil
  defp anthropic_stream_event(_event, _model), do: nil

  defp chunk(id, model, delta, finish_reason \\ nil) do
    %{
      "id" => id || "",
      "object" => "chat.completion.chunk",
      "model" => model,
      "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish_reason}]
    }
  end

  defp anthropic_to_openai_response(response, model) do
    content = response["content"] || []
    {text, tool_calls} = extract_content_parts(content)
    message = build_message(text, tool_calls)
    usage = build_usage(response["usage"] || %{})

    %{
      "id" => response["id"] || "",
      "object" => "chat.completion",
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => message,
          "finish_reason" => map_stop_reason(response["stop_reason"])
        }
      ],
      "usage" => usage
    }
  end

  defp extract_content_parts(content) do
    {text, tools} =
      Enum.reduce(content, {"", []}, fn block, {text_acc, tools_acc} ->
        case block["type"] do
          "text" -> {join_text(text_acc, block["text"]), tools_acc}
          "tool_use" -> {text_acc, [to_openai_tool_call(block) | tools_acc]}
          _ -> {text_acc, tools_acc}
        end
      end)

    {text, Enum.reverse(tools)}
  end

  defp join_text("", new), do: new
  defp join_text(acc, new), do: acc <> "\n" <> new

  defp to_openai_tool_call(block) do
    %{
      "id" => block["id"],
      "type" => "function",
      "function" => %{
        "name" => block["name"],
        "arguments" => Jason.encode!(block["input"] || %{})
      }
    }
  end

  defp build_message(text, []), do: %{"role" => "assistant", "content" => text}

  defp build_message(text, tool_calls) do
    %{"role" => "assistant", "content" => text, "tool_calls" => tool_calls}
  end

  defp build_usage(usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0

    %{
      "prompt_tokens" => input,
      "completion_tokens" => output,
      "total_tokens" => input + output
    }
  end

  defp map_stop_reason("tool_use"), do: "tool_calls"
  defp map_stop_reason("end_turn"), do: "stop"
  defp map_stop_reason("max_tokens"), do: "length"
  defp map_stop_reason(other), do: other
end
