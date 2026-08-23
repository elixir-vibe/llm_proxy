defmodule LLMProxy.ProviderTokenCodec.Plaintext do
  @moduledoc """
  Compatibility codec that keeps provider credentials as plaintext.

  Configure an encryption codec before you store production credentials.
  """

  @behaviour LLMProxy.ProviderTokenCodec

  @impl true
  def encode(value, _context, _options), do: {:ok, value}

  @impl true
  def decode(value, _context, _options), do: {:ok, value}

  @impl true
  def encoded?(_value, _options), do: false
end
