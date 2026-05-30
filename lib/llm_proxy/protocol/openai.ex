defmodule LLMProxy.Protocol.OpenAI do
  @moduledoc """
  OpenAI chat completion protocol.

  Handles conversion between OpenAI format and other protocols.
  """

  @behaviour LLMProxy.Protocol

  alias LLMProxy.Protocol.Request
  alias LLMProxy.Usage
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall

  @impl true
  def protocol, do: :openai

  @spec request_body(Request.t()) :: map()
  def request_body(%Request{} = request) do
    request.body
    |> Map.put("model", request.model)
    |> Map.put("messages", Enum.map(request.messages, &message_to_openai/1))
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

  defp message_to_openai(%Message{role: :system, content: content}) do
    %{"role" => "system", "content" => content_to_openai(content)}
  end

  defp message_to_openai(%Message{role: :user, content: content}) do
    %{"role" => "user", "content" => content_to_openai(content)}
  end

  defp message_to_openai(%Message{role: :assistant, content: content, tool_calls: tool_calls}) do
    %{"role" => "assistant", "content" => content_to_openai(content)}
    |> maybe_put_tool_calls(tool_calls)
  end

  defp message_to_openai(%Message{role: :tool, content: content, tool_call_id: id}) do
    %{"role" => "tool", "tool_call_id" => id, "content" => text_content(content)}
  end

  defp content_to_openai([%ContentPart{type: :text, text: text}]), do: text || ""

  defp content_to_openai(content) do
    Enum.map(content, fn
      %ContentPart{type: :text, text: text} ->
        %{"type" => "text", "text" => text || ""}

      %ContentPart{type: :image_url, url: url} ->
        %{"type" => "image_url", "image_url" => %{"url" => url}}

      %ContentPart{type: :image, data: data, media_type: media_type} ->
        %{"type" => "image_url", "image_url" => %{"url" => data_url(media_type, data)}}

      %ContentPart{type: :file, metadata: %{"file_id" => file_id}} ->
        %{"type" => "file", "file" => %{"file_id" => file_id}}

      %ContentPart{type: :file, filename: filename, data: data} ->
        %{"type" => "file", "file" => %{"filename" => filename, "file_data" => data}}

      %ContentPart{type: :thinking, text: text} ->
        %{"type" => "text", "text" => text || ""}
    end)
  end

  defp data_url(media_type, data), do: "data:#{media_type};base64,#{data}"

  defp text_content(content), do: Enum.map_join(content, "\n", &(&1.text || ""))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_tool_calls(message, nil), do: message
  defp maybe_put_tool_calls(message, []), do: message

  defp maybe_put_tool_calls(message, tool_calls) do
    Map.put(message, "tool_calls", Enum.map(tool_calls, &tool_call_to_openai/1))
  end

  defp tool_call_to_openai(%ToolCall{id: id, type: type, function: function}) do
    %{
      "id" => id,
      "type" => type,
      "function" => %{
        "name" => function.name,
        "arguments" => function.arguments
      }
    }
  end

  defp tool_call_to_openai(%{"function" => _function} = tool_call), do: tool_call
  defp tool_call_to_openai(tool_call), do: tool_call

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
