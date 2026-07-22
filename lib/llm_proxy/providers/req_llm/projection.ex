defmodule LLMProxy.Providers.ReqLLM.Projection do
  @moduledoc false

  alias LLMProxy.Providers.ReqLLM.ErrorProjection
  alias LLMProxy.Stream.Event
  alias LLMProxy.Usage
  alias ReqLLM.{Response, ToolCall}

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

  @spec start_events(String.t()) :: [Event.t()]
  def start_events(model) do
    [Event.new(stream_chunk(model, %{"role" => "assistant"}, nil))]
  end

  @spec events(map(), String.t()) :: [Event.t()]
  def events(%{type: type, text: text}, model) when type in [:content, :thinking] do
    key = if type == :thinking, do: "reasoning_content", else: "content"
    [Event.new(stream_chunk(model, %{key => text}, nil))]
  end

  def events(%{type: type, data: text}, model)
      when type in [:text_delta, :reasoning_delta] do
    key = if type == :reasoning_delta, do: "reasoning_content", else: "content"
    [Event.new(stream_chunk(model, %{key => text}, nil))]
  end

  def events(%{type: :tool_call, name: name, arguments: arguments} = chunk, model) do
    metadata = Map.get(chunk, :metadata, %{})
    index = metadata_value(metadata, :index, 0)

    tool_call = %{
      "index" => index,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => Jason.encode!(arguments)}
    }

    tool_call =
      case metadata_value(metadata, :id) do
        nil -> tool_call
        id -> Map.put(tool_call, "id", id)
      end

    [Event.new(stream_chunk(model, %{"tool_calls" => [tool_call]}, nil))]
  end

  def events(%{type: :tool_call, data: call}, model) do
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

  def events(%{type: :usage, data: stream_usage}, model), do: usage_events(stream_usage, model)

  def events(%{type: :finish, data: data}, model) do
    [Event.new(stream_chunk(model, %{}, finish_reason(data.finish_reason)))]
  end

  def events(%{type: :error, data: error}, _model) do
    [Event.new(%{"error" => ErrorProjection.client_error(error)})]
  end

  def events(%{type: :meta, metadata: metadata}, model) do
    usage_events(metadata_value(metadata, :usage), model) ++
      tool_argument_events(metadata_value(metadata, :tool_call_args), model) ++
      finish_events(metadata, model)
  end

  def events(_event, _model), do: []

  defp usage_events(nil, _model), do: []

  defp usage_events(stream_usage, model) do
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

  defp tool_argument_events(nil, _model), do: []

  defp tool_argument_events(arguments, model) do
    function = %{"arguments" => metadata_value(arguments, :fragment, "")}
    tool_call = %{"index" => metadata_value(arguments, :index, 0), "function" => function}
    [Event.new(stream_chunk(model, %{"tool_calls" => [tool_call]}, nil))]
  end

  defp finish_events(metadata, model) do
    terminal? = metadata_value(metadata, :terminal?, false)
    reason = metadata_value(metadata, :finish_reason)

    if terminal? or not is_nil(reason) do
      [Event.new(stream_chunk(model, %{}, finish_reason(reason)))]
    else
      []
    end
  end

  defp metadata_value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

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
