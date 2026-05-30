defmodule LLMProxy.Trace do
  @moduledoc false

  @spec new_id() :: String.t()
  def new_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
