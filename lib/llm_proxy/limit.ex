defmodule LLMProxy.Limit do
  @moduledoc """
  Usage limit for API keys.
  """

  @metrics [
    :cost_usd,
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :requests
  ]
  @windows [:minute, :hour, :four_hours, :day, :week, :month]

  @derive Jason.Encoder
  defstruct [:metric, :window, :max]

  @type metric :: unquote(Enum.reduce(@metrics, &{:|, [], [&1, &2]}))
  @type window :: unquote(Enum.reduce(@windows, &{:|, [], [&1, &2]}))
  @type t :: %__MODULE__{metric: metric(), window: window(), max: number()}

  @spec cost(window(), number()) :: t()
  def cost(window, max), do: new(:cost_usd, window, max)

  @spec requests(window(), non_neg_integer()) :: t()
  def requests(window, max), do: new(:requests, window, max)

  @spec input_tokens(window(), non_neg_integer()) :: t()
  def input_tokens(window, max), do: new(:input_tokens, window, max)

  @spec output_tokens(window(), non_neg_integer()) :: t()
  def output_tokens(window, max), do: new(:output_tokens, window, max)

  @spec cache_read_tokens(window(), non_neg_integer()) :: t()
  def cache_read_tokens(window, max), do: new(:cache_read_tokens, window, max)

  @spec cache_write_tokens(window(), non_neg_integer()) :: t()
  def cache_write_tokens(window, max), do: new(:cache_write_tokens, window, max)

  @spec new(metric(), window(), number()) :: t()
  def new(metric, window, max)
      when metric in @metrics and window in @windows and is_number(max) and max >= 0 do
    %__MODULE__{metric: metric, window: window, max: max}
  end

  @doc false
  def metrics, do: @metrics

  @doc false
  def windows, do: @windows
end
