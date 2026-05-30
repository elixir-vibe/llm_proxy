defmodule LLMProxy.Web.FormatTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Web.Format

  test "formats numbers, durations, and usd values" do
    assert Format.number(1_500_000) == "1M"
    assert Format.number(1_500) == "1K"
    assert Format.number(10) == "10"

    assert Format.ms(nil) == "—"
    assert Format.ms(1_250) == "1.3s"
    assert Format.ms(250) == "250ms"

    assert Format.usd(nil) == "—"
    assert Format.usd(0) == "$0"
    assert Format.usd(1.25) == "$1.25"
    assert Format.usd(0.125) == "$0.1250"
  end
end
