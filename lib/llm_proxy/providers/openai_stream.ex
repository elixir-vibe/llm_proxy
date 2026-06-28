defmodule LLMProxy.Providers.OpenAIStream do
  @moduledoc """
  Converts OpenAI-compatible SSE payloads into transport-neutral LLMProxy stream events.
  """

  alias LLMProxy.Stream.Event
  alias LLMProxy.Usage

  def to_event(%{data: "[DONE]"}), do: nil

  def to_event(%{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, parsed} -> from_map(parsed)
      {:error, _reason} -> nil
    end
  end

  def to_event(%{data: data}) when is_map(data), do: from_map(data)
  def to_event(_event), do: nil

  def from_map(%{"usage" => usage} = parsed) when is_map(usage) do
    Event.new(parsed, usage: Usage.from_openai(usage))
  end

  def from_map(parsed), do: Event.new(parsed)
end
