defmodule LLMProxy.Provider.Credential do
  @moduledoc """
  Decrypted provider credentials for one provider request.

  Storage schemas keep encoded values. The token pool creates this runtime value
  only after it selects a credential for use at a provider boundary.
  """

  @derive {Inspect, except: [:token, :refresh_token]}
  @enforce_keys [:id, :provider, :kind, :token]
  defstruct [
    :id,
    :provider,
    :kind,
    :token,
    :label,
    :proxy,
    :refresh_token,
    :expires_at,
    :account_id,
    :added_at,
    enabled: true
  ]

  @type t :: %__MODULE__{
          id: integer(),
          provider: String.t(),
          kind: String.t(),
          token: String.t(),
          label: String.t() | nil,
          proxy: String.t() | nil,
          refresh_token: String.t() | nil,
          expires_at: DateTime.t() | nil,
          account_id: String.t() | nil,
          enabled: boolean(),
          added_at: DateTime.t() | nil
        }
end
