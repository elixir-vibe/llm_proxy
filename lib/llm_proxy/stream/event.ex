defmodule LLMProxy.Stream.Event do
  @moduledoc """
  Server-sent stream event with protocol wire-event constructors.
  """

  alias LLMProxy.Usage

  defstruct data: nil, usage: nil, event: nil

  @type t :: %__MODULE__{
          data: map() | String.t(),
          usage: Usage.t() | nil,
          event: String.t() | nil
        }

  @spec new(map() | String.t(), keyword()) :: t()
  def new(data, opts \\ []) do
    %__MODULE__{data: data, usage: Keyword.get(opts, :usage), event: Keyword.get(opts, :event)}
  end

  @spec attach_usage(t(), Usage.t() | nil) :: t()
  def attach_usage(event, nil), do: event
  def attach_usage(%__MODULE__{} = event, usage), do: %{event | usage: usage}

  @spec responses_output_text_delta(String.t()) :: t()
  def responses_output_text_delta(text) when is_binary(text) do
    new(%{"type" => "response.output_text.delta", "delta" => text})
  end

  @spec responses_reasoning_delta(String.t()) :: t()
  def responses_reasoning_delta(text) when is_binary(text) do
    new(%{"type" => "response.reasoning.delta", "delta" => text})
  end

  @spec responses_function_call_added(non_neg_integer(), String.t(), String.t(), map()) :: t()
  def responses_function_call_added(index, id, name, arguments)
      when is_integer(index) and is_binary(id) and is_binary(name) and is_map(arguments) do
    new(%{
      "type" => "response.output_item.added",
      "output_index" => index,
      "item" => %{
        "type" => "function_call",
        "id" => id,
        "call_id" => id,
        "name" => name,
        "arguments" => Jason.encode!(arguments)
      }
    })
  end

  @spec responses_terminal(atom() | nil, String.t(), map()) :: t()
  def responses_terminal(finish_reason, response_id, usage) when is_binary(response_id) do
    rendered_usage = Usage.to_responses(usage)

    new(
      %{
        "type" => responses_terminal_type(finish_reason),
        "response" => %{
          "id" => response_id,
          "status" => responses_status(finish_reason),
          "usage" => rendered_usage
        }
      },
      usage: Usage.from_responses(rendered_usage)
    )
  end

  @spec openai_chat_delta(String.t(), map(), atom() | nil, map() | nil) :: t()
  def openai_chat_delta(model, delta, finish_reason, usage \\ nil)
      when is_binary(model) and is_map(delta) do
    rendered_usage = if usage, do: Usage.to_openai(usage)

    %{
      "id" => "chatcmpl-#{System.unique_integer([:positive])}",
      "object" => "chat.completion.chunk",
      "created" => System.system_time(:second),
      "model" => model,
      "choices" => [
        %{"index" => 0, "delta" => delta, "finish_reason" => openai_finish_reason(finish_reason)}
      ]
    }
    |> maybe_put("usage", rendered_usage)
    |> new()
    |> attach_usage(if(rendered_usage, do: Usage.from_openai(rendered_usage)))
  end

  defp responses_terminal_type(:incomplete), do: "response.incomplete"
  defp responses_terminal_type(_reason), do: "response.completed"

  defp responses_status(:incomplete), do: "incomplete"
  defp responses_status(_reason), do: "completed"

  defp openai_finish_reason(:tool_calls), do: "tool_calls"
  defp openai_finish_reason(:length), do: "length"
  defp openai_finish_reason(:incomplete), do: "length"
  defp openai_finish_reason(nil), do: nil
  defp openai_finish_reason(_reason), do: "stop"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
