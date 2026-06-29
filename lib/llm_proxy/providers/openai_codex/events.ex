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
end
