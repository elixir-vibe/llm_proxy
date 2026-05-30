defmodule LLMProxy.Protocol.Anthropic do
  @moduledoc """
  Anthropic Messages API protocol.

  Handles conversion between Anthropic format and OpenAI format.
  """

  @behaviour LLMProxy.Protocol

  alias LLMProxy.Protocol.Request
  alias LLMProxy.Usage
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall

  @impl true
  def protocol, do: :anthropic

  @impl true
  def convert_response(response, :anthropic, _model), do: response
  def convert_response(response, :openai, model), do: to_anthropic_response(response, model)

  @impl true
  def extract_usage(response) do
    usage = response["usage"] || %{}

    Usage.from_anthropic(usage)
  end

  # --- OpenAI → Anthropic ---

  @spec request_body(Request.t()) :: map()
  def request_body(%Request{} = request) do
    {system_messages, messages} = Enum.split_with(request.messages, &(&1.role == :system))

    base = %{
      "model" => request.model,
      "messages" => Enum.map(messages, &message_to_anthropic/1),
      "max_tokens" => request.max_tokens || 4096
    }

    base
    |> maybe_put_system_messages(system_messages)
    |> maybe_put_tools(request.tools)
    |> maybe_put("temperature", request.temperature)
    |> maybe_put("top_p", request.top_p)
    |> maybe_put("stream", request.stream)
    |> maybe_put("metadata", request.metadata)
    |> maybe_put("stop_sequences", request.stop)
    |> maybe_put("tool_choice", request.tool_choice)
  end

  defp message_to_anthropic(%Message{role: :user, content: content}) do
    %{"role" => "user", "content" => content_to_anthropic(content)}
  end

  defp message_to_anthropic(%Message{role: :assistant, content: content, tool_calls: tool_calls}) do
    %{"role" => "assistant", "content" => content_blocks(content) ++ tool_call_blocks(tool_calls)}
  end

  defp message_to_anthropic(%Message{role: :tool, content: content, tool_call_id: id}) do
    %{
      "role" => "user",
      "content" => [
        %{"type" => "tool_result", "tool_use_id" => id, "content" => text_content(content)}
      ]
    }
  end

  defp content_to_anthropic([%ContentPart{type: :text, text: text}]), do: text || ""
  defp content_to_anthropic(content), do: content_blocks(content)

  defp content_blocks(content) do
    Enum.map(content, fn
      %ContentPart{type: :text, text: text} ->
        %{"type" => "text", "text" => text || ""}

      %ContentPart{type: :image_url, url: url} ->
        %{"type" => "image", "source" => %{"type" => "url", "url" => url}}

      %ContentPart{type: :thinking, metadata: %{"redacted" => true, "data" => data}} ->
        %{"type" => "redacted_thinking", "data" => data}

      %ContentPart{type: :thinking, text: text, metadata: metadata} ->
        %{"type" => "thinking", "thinking" => text || ""}
        |> maybe_put("signature", metadata["signature"])

      %ContentPart{type: :image, data: data, media_type: media_type} ->
        %{
          "type" => "image",
          "source" => %{"type" => "base64", "media_type" => media_type, "data" => data}
        }
    end)
  end

  defp tool_call_blocks(nil), do: []
  defp tool_call_blocks([]), do: []
  defp tool_call_blocks(tool_calls), do: Enum.map(tool_calls, &tool_call_block/1)

  defp tool_call_block(%ToolCall{id: id, function: %{name: name, arguments: arguments}}) do
    %{"type" => "tool_use", "id" => id, "name" => name, "input" => parse_arguments(arguments)}
  end

  defp text_content(content), do: Enum.map_join(content, "\n", &(&1.text || ""))

  defp maybe_put_system_messages(body, []), do: body

  defp maybe_put_system_messages(body, system_messages) do
    system = Enum.flat_map(system_messages, &content_blocks(&1.content))
    Map.put(body, "system", system)
  end

  defp build_assistant_text_blocks(nil), do: []
  defp build_assistant_text_blocks(""), do: []

  defp build_assistant_text_blocks(text) when is_binary(text),
    do: [%{"type" => "text", "text" => text}]

  defp build_assistant_text_blocks(_), do: []

  defp parse_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      {:error, _} -> %{}
    end
  end

  defp parse_arguments(args) when is_map(args), do: args
  defp parse_arguments(_), do: %{}

  defp maybe_put_tools(body, nil), do: body
  defp maybe_put_tools(body, []), do: body

  defp maybe_put_tools(body, tools) do
    Map.put(body, "tools", Enum.map(tools, &convert_tool_to_anthropic/1))
  end

  defp convert_tool_to_anthropic(%{"function" => func}) do
    %{
      "name" => func["name"],
      "description" => func["description"] || "",
      "input_schema" => func["parameters"] || %{}
    }
  end

  defp convert_tool_to_anthropic(tool), do: tool

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_anthropic_response(response, model) do
    choice = List.first(response["choices"] || []) || %{}
    message = choice["message"] || %{}

    %{
      "id" => response["id"] || "",
      "type" => "message",
      "role" => "assistant",
      "model" => model,
      "content" => openai_message_to_anthropic_content(message),
      "stop_reason" => map_finish_reason(choice["finish_reason"]),
      "usage" => openai_usage_to_anthropic(response["usage"] || %{})
    }
  end

  defp openai_message_to_anthropic_content(message) do
    text_blocks = build_assistant_text_blocks(message["content"])

    tool_blocks =
      Enum.map(message["tool_calls"] || [], fn tool_call ->
        %{
          "type" => "tool_use",
          "id" => tool_call["id"],
          "name" => get_in(tool_call, ["function", "name"]),
          "input" => parse_arguments(get_in(tool_call, ["function", "arguments"]))
        }
      end)

    text_blocks ++ tool_blocks
  end

  defp openai_usage_to_anthropic(usage) do
    %{
      "input_tokens" => usage["prompt_tokens"] || 0,
      "output_tokens" => usage["completion_tokens"] || 0
    }
  end

  defp map_finish_reason("tool_calls"), do: "tool_use"
  defp map_finish_reason("stop"), do: "end_turn"
  defp map_finish_reason("length"), do: "max_tokens"
  defp map_finish_reason(other), do: other
end
