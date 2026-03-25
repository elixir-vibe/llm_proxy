defmodule LLMProxy.Protocol.Anthropic do
  @moduledoc """
  Anthropic Messages API protocol.

  Handles conversion between Anthropic format and OpenAI format.
  """

  @behaviour LLMProxy.Protocol

  @impl true
  def protocol, do: :anthropic

  @impl true
  def convert_request(body, :anthropic), do: body
  def convert_request(body, :openai), do: from_anthropic(body)

  @impl true
  def convert_response(response, :anthropic, _model), do: response
  def convert_response(response, :openai, model), do: to_anthropic_response(response, model)

  @impl true
  def extract_usage(response) do
    usage = response["usage"] || %{}

    %{
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      cache_read_tokens: usage["cache_read_input_tokens"] || 0,
      cache_write_tokens: usage["cache_creation_input_tokens"] || 0
    }
  end

  # --- OpenAI → Anthropic ---

  @doc "Convert an OpenAI chat completion request body to Anthropic Messages format"
  def from_openai(body) do
    {system_msgs, other_msgs} = Enum.split_with(body["messages"] || [], &system?/1)

    base = %{
      "model" => body["model"],
      "messages" => Enum.map(other_msgs, &convert_message_to_anthropic/1),
      "max_tokens" => body["max_tokens"] || 4096
    }

    base
    |> maybe_put_system(system_msgs)
    |> maybe_put_tools(body["tools"])
    |> maybe_put("temperature", body["temperature"])
  end

  defp system?(%{"role" => "system"}), do: true
  defp system?(_), do: false

  defp convert_message_to_anthropic(%{"role" => "assistant", "tool_calls" => tool_calls} = msg) do
    text_blocks = build_assistant_text_blocks(msg["content"])
    tool_blocks = Enum.map(tool_calls, &convert_tool_call/1)

    %{"role" => "assistant", "content" => text_blocks ++ tool_blocks}
  end

  defp convert_message_to_anthropic(%{"role" => "tool"} = msg) do
    %{
      "role" => "user",
      "content" => [
        %{
          "type" => "tool_result",
          "tool_use_id" => msg["tool_call_id"],
          "content" => msg["content"] || ""
        }
      ]
    }
  end

  defp convert_message_to_anthropic(msg), do: msg

  defp build_assistant_text_blocks(nil), do: []
  defp build_assistant_text_blocks(""), do: []
  defp build_assistant_text_blocks(text) when is_binary(text), do: [%{"type" => "text", "text" => text}]
  defp build_assistant_text_blocks(_), do: []

  defp convert_tool_call(%{"function" => func} = tc) do
    %{
      "type" => "tool_use",
      "id" => tc["id"],
      "name" => func["name"],
      "input" => parse_arguments(func["arguments"])
    }
  end

  defp parse_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      {:error, _} -> %{}
    end
  end

  defp parse_arguments(args) when is_map(args), do: args
  defp parse_arguments(_), do: %{}

  defp maybe_put_system(body, []), do: body

  defp maybe_put_system(body, system_msgs) do
    system = Enum.map(system_msgs, fn msg -> %{"type" => "text", "text" => msg["content"]} end)
    Map.put(body, "system", system)
  end

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

  # --- Anthropic → OpenAI (for convert_request to :openai) ---

  defp from_anthropic(_body) do
    raise "Anthropic→OpenAI request conversion not yet implemented"
  end

  defp to_anthropic_response(_response, _model) do
    raise "OpenAI→Anthropic response conversion not yet implemented"
  end
end
