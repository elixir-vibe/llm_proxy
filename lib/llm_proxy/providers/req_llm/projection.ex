defmodule LLMProxy.Providers.ReqLLM.Projection do
  @moduledoc false

  alias LLMProxy.Stream.Event
  alias LLMProxy.Usage
  alias ReqLLM.{Response, StreamEvent, ToolCall}

  @spec response(Response.t(), String.t()) :: map()
  def response(%Response{} = response, model) do
    %{
      "id" => response.id,
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => message(response),
          "finish_reason" => finish_reason(response.finish_reason)
        }
      ],
      "usage" => usage(response.usage)
    }
  end

  @spec events(StreamEvent.t(), String.t()) :: [Event.t()]
  def events(%StreamEvent{type: :start}, model) do
    [Event.new(stream_chunk(model, %{"role" => "assistant"}, nil))]
  end

  def events(%StreamEvent{type: :text_delta, data: text}, model) do
    [Event.new(stream_chunk(model, %{"content" => text}, nil))]
  end

  def events(%StreamEvent{type: :reasoning_delta, data: text}, model) do
    [Event.new(stream_chunk(model, %{"reasoning_content" => text}, nil))]
  end

  def events(%StreamEvent{type: :tool_call, data: call}, model) do
    delta = %{
      "tool_calls" => [
        %{
          "index" => 0,
          "id" => call.id,
          "type" => "function",
          "function" => %{"name" => call.name, "arguments" => Jason.encode!(call.arguments)}
        }
      ]
    }

    [Event.new(stream_chunk(model, delta, nil))]
  end

  def events(%StreamEvent{type: :usage, data: stream_usage}, model) do
    rendered = usage(stream_usage)

    data = %{
      "id" => stream_id(model),
      "object" => "chat.completion.chunk",
      "model" => model,
      "choices" => [],
      "usage" => rendered
    }

    [Event.new(data, usage: Usage.from_openai(rendered))]
  end

  def events(%StreamEvent{type: :finish, data: data}, model) do
    [Event.new(stream_chunk(model, %{}, finish_reason(data.finish_reason)))]
  end

  def events(%StreamEvent{type: :error, data: error}, _model) do
    [Event.new(%{"error" => %{"message" => inspect(error), "type" => "api_error"}})]
  end

  def events(_event, _model), do: []

  defp message(response) do
    %{"role" => "assistant", "content" => Response.text(response)}
    |> put_non_empty("reasoning_content", Response.thinking(response))
    |> put_tool_calls(Response.tool_calls(response))
  end

  defp put_non_empty(map, _key, value) when value in [nil, ""], do: map
  defp put_non_empty(map, key, value), do: Map.put(map, key, value)

  defp put_tool_calls(message, []), do: message

  defp put_tool_calls(message, tool_calls) do
    calls =
      Enum.map(tool_calls, fn tool_call ->
        %{id: id, name: name, arguments: arguments} = ToolCall.to_map(tool_call)

        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => name, "arguments" => Jason.encode!(arguments)}
        }
      end)

    Map.put(message, "tool_calls", calls)
  end

  defp stream_chunk(model, delta, finish_reason) do
    %{
      "id" => stream_id(model),
      "object" => "chat.completion.chunk",
      "created" => System.system_time(:second),
      "model" => model,
      "choices" => [
        %{"index" => 0, "delta" => delta, "finish_reason" => finish_reason}
      ]
    }
  end

  defp stream_id(model), do: "chatcmpl-llm-proxy-#{model}"

  defp usage(nil) do
    %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}
  end

  defp usage(values) when is_map(values) do
    input = usage_value(values, [:input_tokens, :input], 0)
    output = usage_value(values, [:output_tokens, :output], 0)
    cached = usage_value(values, [:cached_tokens, :cached_input, :cache_read_tokens], 0)

    %{
      "prompt_tokens" => input,
      "completion_tokens" => output,
      "total_tokens" => usage_value(values, [:total_tokens], input + output),
      "prompt_tokens_details" => %{"cached_tokens" => cached}
    }
  end

  defp usage_value(usage, keys, default) do
    Enum.find_value(keys, default, fn key ->
      Map.get(usage, key) || Map.get(usage, Atom.to_string(key))
    end)
  end

  defp finish_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp finish_reason(reason) when is_binary(reason), do: reason
  defp finish_reason(_reason), do: nil
end
