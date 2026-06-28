defmodule LLMProxy.Response do
  @moduledoc """
  Internal non-stream LLMProxy response.

  The generated model turn is stored as a canonical `ReqLLM.Response` struct.
  HTTP routes render protocol wire maps at the boundary with `to_openai/1`.
  """

  alias LLMProxy.Protocol.Request
  alias LLMProxy.Usage
  alias ReqLLM.{Message, ToolCall}
  alias ReqLLM.Message.ContentPart

  @enforce_keys [:message, :provider_response, :provider, :model, :request]
  defstruct [
    :message,
    :provider_response,
    :provider,
    :model,
    :request,
    :trace_id,
    cache_hit: false,
    cacheable: true,
    cache_ttl_ms: nil,
    usage: Usage.zero()
  ]

  @type t :: %__MODULE__{
          message: ReqLLM.Response.t(),
          provider_response: term(),
          provider: module(),
          model: String.t(),
          request: Request.t(),
          trace_id: String.t() | nil,
          cache_hit: boolean(),
          cacheable: boolean(),
          cache_ttl_ms: pos_integer() | nil,
          usage: Usage.t()
        }

  @spec to_openai(t()) :: map()
  def to_openai(%__MODULE__{} = response) do
    %{
      "id" => response.message.id || "llm_proxy",
      "object" => "chat.completion",
      "model" => response.model,
      "choices" => [
        %{
          "index" => 0,
          "message" => openai_message(response.message.message),
          "finish_reason" => openai_finish_reason(response.message.finish_reason)
        }
      ],
      "usage" => Usage.to_openai(response.usage)
    }
  end

  @spec put_text(t(), String.t()) :: t()
  def put_text(%__MODULE__{message: %ReqLLM.Response{} = message} = response, text)
      when is_binary(text) do
    assistant = %Message{role: :assistant, content: [ContentPart.text(text)]}
    %{response | message: %{message | message: assistant}}
  end

  defp openai_message(%Message{role: :assistant, content: content, tool_calls: tool_calls}) do
    %{"role" => "assistant", "content" => text_content(content)}
    |> maybe_put_tool_calls(tool_calls)
  end

  defp openai_message(_message), do: %{"role" => "assistant", "content" => ""}

  defp text_content(content) when is_list(content) do
    content
    |> Enum.filter(&match?(%ContentPart{type: :text}, &1))
    |> Enum.map_join("\n", &(&1.text || ""))
  end

  defp maybe_put_tool_calls(message, nil), do: message
  defp maybe_put_tool_calls(message, []), do: message

  defp maybe_put_tool_calls(message, tool_calls) do
    Map.put(message, "tool_calls", Enum.map(tool_calls, &openai_tool_call/1))
  end

  defp openai_tool_call(%ToolCall{id: id, type: type, function: function}) do
    %{
      "id" => id,
      "type" => type,
      "function" => %{
        "name" => function.name,
        "arguments" => function.arguments
      }
    }
  end

  defp openai_tool_call(tool_call) when is_map(tool_call), do: tool_call

  defp openai_finish_reason(:stop), do: "stop"
  defp openai_finish_reason(:length), do: "length"
  defp openai_finish_reason(:tool_calls), do: "tool_calls"
  defp openai_finish_reason(:content_filter), do: "content_filter"
  defp openai_finish_reason(nil), do: nil
  defp openai_finish_reason(other), do: to_string(other)
end
