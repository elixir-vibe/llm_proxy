defmodule LLMProxy.Provider.TokenCodec.Plaintext do
  @moduledoc """
  Compatibility codec that keeps provider credentials as plaintext.

  Configure an encryption codec before you store production credentials. The
  codec rejects LLMProxy's encrypted envelope so missing keyring configuration
  fails closed instead of forwarding ciphertext as an upstream credential.
  """

  @behaviour LLMProxy.Provider.TokenCodec

  alias LLMProxy.Provider.TokenCodec

  @impl true
  def validate_options(_options), do: :ok

  @impl true
  def encode(value, _context, _options), do: reject_encrypted_envelope(value)

  @impl true
  def decode(value, _context, _options), do: reject_encrypted_envelope(value)

  @impl true
  def encoded?(_value, _options), do: false

  defp reject_encrypted_envelope(value) do
    if TokenCodec.built_in_envelope?(value) do
      {:error, :encrypted_value_requires_keyring}
    else
      {:ok, value}
    end
  end
end
