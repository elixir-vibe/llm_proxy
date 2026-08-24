defmodule LLMProxy.Stream.Event do
  @moduledoc """
  Server-sent stream event with protocol wire-event constructors.
  """

  alias LLMProxy.Usage

  @type kind ::
          :start | :content | :reasoning | :tool_call | :usage | :finish | :error | :metadata

  defstruct data: nil, usage: nil, event: nil, kind: :metadata

  @type t :: %__MODULE__{
          data: map() | String.t(),
          usage: Usage.t() | nil,
          event: String.t() | nil,
          kind: kind()
        }

  @spec new(map() | String.t(), keyword()) :: t()
  def new(data, opts \\ []) do
    %__MODULE__{
      data: data,
      usage: Keyword.get(opts, :usage),
      event: Keyword.get(opts, :event),
      kind: Keyword.get(opts, :kind, :metadata)
    }
  end

  @spec output_delta?(t()) :: boolean()
  def output_delta?(%__MODULE__{kind: kind}) when kind in [:content, :reasoning, :tool_call],
    do: true

  def output_delta?(%__MODULE__{}), do: false

  @spec attach_usage(t(), Usage.t() | nil) :: t()
  def attach_usage(event, nil), do: event
  def attach_usage(%__MODULE__{} = event, usage), do: %{event | usage: usage}

  @spec from_openai_sse(%{optional(:data) => term()}) :: t() | nil
  def from_openai_sse(%{data: "[DONE]"}), do: nil

  def from_openai_sse(%{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, parsed} -> from_openai_map(parsed)
      {:error, _reason} -> nil
    end
  end

  def from_openai_sse(%{data: data}) when is_map(data), do: from_openai_map(data)
  def from_openai_sse(_event), do: nil

  @spec from_openai_map(map()) :: t()
  def from_openai_map(%{"usage" => usage} = parsed) when is_map(usage) do
    new(parsed, usage: Usage.from_openai(usage), kind: openai_kind(parsed))
  end

  def from_openai_map(parsed), do: new(parsed, kind: openai_kind(parsed))

  @spec responses_output_text_delta(String.t()) :: t()
  def responses_output_text_delta(text) when is_binary(text) do
    new(%{"type" => "response.output_text.delta", "delta" => text}, kind: :content)
  end

  @spec responses_reasoning_delta(String.t()) :: t()
  def responses_reasoning_delta(text) when is_binary(text) do
    new(%{"type" => "response.reasoning.delta", "delta" => text}, kind: :reasoning)
  end

  @spec responses_function_call_added(non_neg_integer(), String.t(), String.t(), map()) :: t()
  def responses_function_call_added(index, id, name, arguments)
      when is_integer(index) and is_binary(id) and is_binary(name) and is_map(arguments) do
    new(
      %{
        "type" => "response.output_item.added",
        "output_index" => index,
        "item" => %{
          "type" => "function_call",
          "id" => id,
          "call_id" => id,
          "name" => name,
          "arguments" => Jason.encode!(arguments)
        }
      },
      kind: :tool_call
    )
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
      usage: Usage.from_responses(rendered_usage),
      kind: :finish
    )
  end

  @spec openai_chat_content_delta(String.t(), String.t()) :: t()
  def openai_chat_content_delta(model, text) when is_binary(model) and is_binary(text) do
    openai_chat_delta(model, %{"content" => text}, nil)
  end

  @spec openai_chat_tool_call_delta(non_neg_integer(), String.t(), String.t(), map(), String.t()) ::
          t()
  def openai_chat_tool_call_delta(index, id, name, arguments, model)
      when is_integer(index) and is_binary(id) and is_binary(name) and is_map(arguments) and
             is_binary(model) do
    openai_chat_delta(
      model,
      %{
        "tool_calls" => [
          %{
            "index" => index,
            "id" => id,
            "type" => "function",
            "function" => %{
              "name" => name,
              "arguments" => openai_tool_call_arguments(arguments)
            }
          }
        ]
      },
      nil
    )
  end

  @spec openai_chat_tool_call_arguments_delta(non_neg_integer(), String.t(), String.t()) :: t()
  def openai_chat_tool_call_arguments_delta(index, fragment, model)
      when is_integer(index) and is_binary(fragment) and is_binary(model) do
    openai_chat_delta(
      model,
      %{"tool_calls" => [%{"index" => index, "function" => %{"arguments" => fragment}}]},
      nil
    )
  end

  @spec openai_chat_terminal(String.t(), atom() | nil, map() | nil) :: t()
  def openai_chat_terminal(model, finish_reason, usage) when is_binary(model) do
    openai_chat_delta(model, %{}, finish_reason, usage)
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
    |> new(kind: openai_delta_kind(delta, finish_reason))
    |> attach_usage(if(rendered_usage, do: Usage.from_openai(rendered_usage)))
  end

  defp openai_kind(%{"choices" => [%{"delta" => delta, "finish_reason" => finish_reason} | _]})
       when is_map(delta),
       do: openai_delta_kind(delta, finish_reason)

  defp openai_kind(%{"usage" => usage}) when is_map(usage), do: :usage
  defp openai_kind(%{"error" => _error}), do: :error
  defp openai_kind(_parsed), do: :metadata

  defp openai_delta_kind(%{"content" => content}, _finish_reason)
       when is_binary(content) and content != "",
       do: :content

  defp openai_delta_kind(%{"reasoning_content" => content}, _finish_reason)
       when is_binary(content) and content != "",
       do: :reasoning

  defp openai_delta_kind(%{"tool_calls" => calls}, _finish_reason)
       when is_list(calls) and calls != [],
       do: :tool_call

  defp openai_delta_kind(%{"role" => _role}, nil), do: :start
  defp openai_delta_kind(_delta, finish_reason) when not is_nil(finish_reason), do: :finish
  defp openai_delta_kind(_delta, _finish_reason), do: :metadata

  defp responses_terminal_type(:incomplete), do: "response.incomplete"
  defp responses_terminal_type(_reason), do: "response.completed"

  defp responses_status(:incomplete), do: "incomplete"
  defp responses_status(_reason), do: "completed"

  defp openai_tool_call_arguments(arguments) when arguments == %{}, do: ""
  defp openai_tool_call_arguments(arguments), do: Jason.encode!(arguments)

  defp openai_finish_reason(:tool_calls), do: "tool_calls"
  defp openai_finish_reason(:length), do: "length"
  defp openai_finish_reason(:incomplete), do: "length"
  defp openai_finish_reason(nil), do: nil
  defp openai_finish_reason(_reason), do: "stop"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
