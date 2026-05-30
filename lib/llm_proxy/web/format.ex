defmodule LLMProxy.Web.Format do
  @moduledoc false

  def number(n) when is_integer(n) and n >= 1_000_000, do: "#{div(n, 1_000_000)}M"
  def number(n) when is_integer(n) and n >= 1_000, do: "#{div(n, 1_000)}K"
  def number(n), do: to_string(n)

  def ms(nil), do: "—"
  def ms(ms) when ms >= 1000, do: "#{Float.round(ms / 1000, 1)}s"
  def ms(ms), do: "#{ms}ms"

  def usd(nil), do: "—"
  def usd(0), do: "$0"
  def usd(n) when is_float(n) and n >= 1.0, do: "$#{:erlang.float_to_binary(n, decimals: 2)}"
  def usd(n) when is_float(n), do: "$#{:erlang.float_to_binary(n, decimals: 4)}"
  def usd(n) when is_number(n), do: usd(n / 1)
end
