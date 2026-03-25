defmodule LLMProxy.Protocol.OpenAI do
  @moduledoc """
  OpenAI chat completion protocol.

  Handles conversion between OpenAI format and other protocols.
  """

  @behaviour LLMProxy.Protocol

  @impl true
  def protocol, do: :openai

  @impl true
  def convert_request(body, :openai), do: body

  def convert_request(body, :anthropic) do
    LLMProxy.Protocol.Anthropic.from_openai(body)
  end

  @impl true
  def convert_response(response, :openai, model) do
    Map.put(response, "model", model)
  end

  def convert_response(response, :anthropic, model) do
    anthropic_to_openai_response(response, model)
  end

  @impl true
  def extract_usage(response) do
    usage = response["usage"] || %{}
    cache_read = get_in(response, ["usage", "prompt_tokens_details", "cached_tokens"]) || 0

    %{
      input_tokens: usage["prompt_tokens"] || 0,
      output_tokens: usage["completion_tokens"] || 0,
      cache_read_tokens: cache_read,
      cache_write_tokens: 0
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
    Enum.reduce(content, {"", []}, fn block, {text_acc, tools_acc} ->
      case block["type"] do
        "text" -> {join_text(text_acc, block["text"]), tools_acc}
        "tool_use" -> {text_acc, tools_acc ++ [to_openai_tool_call(block)]}
        _ -> {text_acc, tools_acc}
      end
    end)
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
