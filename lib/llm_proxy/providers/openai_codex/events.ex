defmodule LLMProxy.Providers.OpenAICodex.Events do
  @moduledoc """
  Converts ReqLLM Codex stream chunks into LLMProxy stream events.

  Codex execution stays in `LLMProxy.Providers.OpenAICodex`; this module owns
  only the wire-shape adaptation from `ReqLLM.StreamChunk` to the OpenAI Chat
  and OpenAI Responses event formats exposed by LLMProxy routes.
  """

  alias LLMProxy.Stream.Event
  alias ReqLLM.StreamChunk

  @spec responses_event(StreamChunk.t()) :: Event.t() | nil
  def responses_event(%StreamChunk{type: :content, text: text}) when is_binary(text) do
    Event.responses_output_text_delta(text)
  end

  def responses_event(%StreamChunk{type: :thinking, text: text}) when is_binary(text) do
    Event.responses_reasoning_delta(text)
  end

  def responses_event(%StreamChunk{type: :tool_call} = chunk) do
    index = Map.get(chunk.metadata, :index, 0)
    id = Map.get(chunk.metadata, :id) || "call_#{System.unique_integer([:positive])}"

    Event.responses_function_call_added(index, id, chunk.name, chunk.arguments || %{})
  end

  def responses_event(%StreamChunk{type: :meta, metadata: metadata}) do
    if metadata[:terminal?] do
      Event.responses_terminal(
        metadata[:finish_reason],
        metadata[:response_id] || "resp_#{System.unique_integer([:positive])}",
        metadata[:usage]
      )
    end
  end

  def responses_event(_chunk), do: nil

  @spec openai_chat_events(Enumerable.t(), String.t()) :: Enumerable.t()
  def openai_chat_events(stream, model) when is_binary(model) do
    Stream.transform(stream, %{indexes: %{}, next_index: 0, saw_tools?: false}, fn chunk, state ->
      case openai_chat_event(chunk, model, state) do
        {nil, state} -> {[], state}
        {event, state} -> {[event], state}
      end
    end)
  end

  @spec openai_chat_event(StreamChunk.t(), String.t()) :: Event.t() | nil
  def openai_chat_event(%StreamChunk{type: :content, text: text}, model) when is_binary(text) do
    Event.openai_chat_content_delta(model, text)
  end

  def openai_chat_event(%StreamChunk{type: :tool_call} = chunk, model) do
    index = Map.get(chunk.metadata, :index, 0)
    id = Map.get(chunk.metadata, :id) || "call_#{System.unique_integer([:positive])}"

    Event.openai_chat_tool_call_delta(index, id, chunk.name, chunk.arguments || %{}, model)
  end

  def openai_chat_event(%StreamChunk{type: :meta, metadata: metadata}, model) do
    if metadata[:terminal?] do
      Event.openai_chat_terminal(model, metadata[:finish_reason], metadata[:usage])
    end
  end

  def openai_chat_event(_chunk, _model), do: nil

  defp openai_chat_event(%StreamChunk{type: :content, text: text}, model, state)
       when is_binary(text) do
    {Event.openai_chat_content_delta(model, text), state}
  end

  defp openai_chat_event(%StreamChunk{type: :tool_call} = chunk, model, state) do
    external_index = chunk_index(chunk.metadata)
    {index, state} = stream_index(state, external_index)
    id = Map.get(chunk.metadata, :id) || Map.get(chunk.metadata, "id") || call_id(index)

    {Event.openai_chat_tool_call_delta(index, id, chunk.name, chunk.arguments || %{}, model),
     %{state | saw_tools?: true}}
  end

  defp openai_chat_event(
         %StreamChunk{type: :meta, metadata: %{tool_call_args: args}},
         model,
         state
       ) do
    external_index = Map.get(args, :index, Map.get(args, "index", 0))
    fragment = Map.get(args, :fragment, Map.get(args, "fragment", ""))
    {index, state} = stream_index(state, external_index)

    if is_binary(fragment) and fragment != "" do
      {Event.openai_chat_tool_call_arguments_delta(index, fragment, model), state}
    else
      {nil, state}
    end
  end

  defp openai_chat_event(%StreamChunk{type: :meta, metadata: metadata}, model, state) do
    if metadata[:terminal?] do
      finish_reason = terminal_finish_reason(metadata[:finish_reason], state)
      {Event.openai_chat_terminal(model, finish_reason, metadata[:usage]), state}
    else
      {nil, state}
    end
  end

  defp openai_chat_event(_chunk, _model, state), do: {nil, state}

  defp chunk_index(metadata), do: Map.get(metadata, :index, Map.get(metadata, "index", 0))

  defp stream_index(%{indexes: indexes, next_index: next_index} = state, external_index) do
    case Map.fetch(indexes, external_index) do
      {:ok, index} ->
        {index, state}

      :error ->
        {next_index,
         %{
           state
           | indexes: Map.put(indexes, external_index, next_index),
             next_index: next_index + 1
         }}
    end
  end

  defp terminal_finish_reason(reason, %{saw_tools?: true})
       when reason not in [:length, :incomplete],
       do: :tool_calls

  defp terminal_finish_reason(reason, _state), do: reason

  defp call_id(index), do: "call_#{index}_#{System.unique_integer([:positive])}"
end
