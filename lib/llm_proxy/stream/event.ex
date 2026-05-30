defmodule LLMProxy.Stream.Event do
  @moduledoc false

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
end
