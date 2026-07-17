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
    :provider_name,
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
          provider_name: String.t() | nil,
          model: String.t(),
          request: Request.t(),
          trace_id: String.t() | nil,
          cache_hit: boolean(),
          cacheable: boolean(),
          cache_ttl_ms: pos_integer() | nil,
          usage: Usage.t()
        }

  @spec to_openai(t()) :: map()
  def to_openai(
        %__MODULE__{provider_response: %{"choices" => choices} = provider_response} = response
      )
      when is_list(choices) do
    provider_response
    |> Map.put("model", response.model)
    |> update_in(["choices", Access.all(), "message"], fn
      %{} = message -> Map.put_new(message, "role", "assistant")
      message -> message
    end)
  end

  def to_openai(%__MODULE__{} = response) do
    to_openai_chat_completion(
      response.message,
      response.model,
      response.message.id || "llm_proxy",
      response.usage,
      ""
    )
  end

  @spec to_openai_chat_completion(
          ReqLLM.Response.t(),
          String.t(),
          String.t(),
          Usage.t() | map() | nil,
          String.t() | nil,
          pos_integer() | nil
        ) :: map()
  def to_openai_chat_completion(
        %ReqLLM.Response{} = response,
        model,
        id,
        usage,
        empty_content,
        created_at \\ nil
      )
      when is_binary(model) and is_binary(id) do
    %{
      "id" => id,
      "object" => "chat.completion",
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => openai_message(response.message, empty_content),
          "finish_reason" => openai_finish_reason(response.finish_reason)
        }
      ],
      "usage" => Usage.to_openai(usage)
    }
    |> maybe_put("created", created_at)
  end

  @spec to_responses(ReqLLM.Response.t(), String.t(), pos_integer() | nil) :: map()
  def to_responses(%ReqLLM.Response{} = response, model, created_at \\ nil)
      when is_binary(model) do
    %{
      "id" => response.id,
      "object" => "response",
      "model" => model,
      "status" => responses_status(response.finish_reason),
      "output" => responses_output(response),
      "usage" => Usage.to_responses(response.usage)
    }
    |> maybe_put("created_at", created_at)
  end

  @spec put_text(t(), String.t()) :: t()
  def put_text(%__MODULE__{message: %ReqLLM.Response{} = message} = response, text)
      when is_binary(text) do
    assistant = %Message{role: :assistant, content: [ContentPart.text(text)]}

    %{
      response
      | message: %{message | message: assistant},
        provider_response: put_provider_text(response.provider_response, text)
    }
  end

  defp put_provider_text(%{"choices" => choices} = provider_response, text)
       when is_list(choices) do
    update_in(provider_response, ["choices", Access.all(), "message"], fn
      %{} = message ->
        message
        |> Map.put("role", "assistant")
        |> Map.put("content", text)
        |> Map.delete("tool_calls")

      message ->
        message
    end)
  end

  defp put_provider_text(provider_response, _text), do: provider_response

  defp openai_message(
         %Message{role: :assistant, content: content, tool_calls: tool_calls},
         empty_content
       ) do
    content = text_content(content)

    %{"role" => "assistant", "content" => if(content == "", do: empty_content, else: content)}
    |> maybe_put_tool_calls(tool_calls)
  end

  defp openai_message(_message, empty_content),
    do: %{"role" => "assistant", "content" => empty_content}

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
  defp openai_finish_reason(:incomplete), do: "length"
  defp openai_finish_reason(nil), do: nil
  defp openai_finish_reason(other), do: to_string(other)

  defp responses_output(%ReqLLM.Response{} = response) do
    response
    |> responses_text_output()
    |> Kernel.++(Enum.map(ReqLLM.Response.tool_calls(response), &responses_tool_call/1))
  end

  defp responses_text_output(%ReqLLM.Response{} = response) do
    case ReqLLM.Response.text(response) || "" do
      "" ->
        []

      text ->
        [
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}],
            "status" => "completed"
          }
        ]
    end
  end

  defp responses_tool_call(tool_call) do
    %{
      "type" => "function_call",
      "id" => tool_call.id,
      "call_id" => tool_call.id,
      "name" => ReqLLM.ToolCall.name(tool_call),
      "arguments" => ReqLLM.ToolCall.args_json(tool_call)
    }
  end

  defp responses_status(:incomplete), do: "incomplete"
  defp responses_status(_reason), do: "completed"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
