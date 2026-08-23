defmodule LLMProxy.ProviderTokenCodec do
  @moduledoc """
  Configurable encoding boundary for provider API keys and OAuth tokens.

  A codec receives the credential field as context. This lets a codec bind its
  ciphertext to the field and prevents an access token from being used as a
  refresh token. Configure a module or a `{module, options}` tuple with
  `:provider_token_codec`.
  """

  alias LLMProxy.ProviderCredential
  alias LLMProxy.Schemas.ProviderToken

  @type context :: %{required(:field) => :token | :refresh_token}
  @type options :: keyword() | map()

  @callback encode(String.t(), context(), options()) ::
              {:ok, String.t()} | {:error, term()}
  @callback decode(String.t(), context(), options()) ::
              {:ok, String.t()} | {:error, term()}
  @callback encoded?(String.t(), options()) :: boolean()

  @secret_fields [:token, :refresh_token]

  @spec encode(String.t() | nil, :token | :refresh_token) ::
          {:ok, String.t() | nil} | {:error, term()}
  def encode(nil, _field), do: {:ok, nil}
  def encode("", _field), do: {:ok, ""}

  def encode(value, field) when is_binary(value) and field in @secret_fields do
    with {:ok, module, options} <- configured() do
      module.encode(value, %{field: field}, options)
    end
  end

  @spec decode(String.t() | nil, :token | :refresh_token) ::
          {:ok, String.t() | nil} | {:error, term()}
  def decode(nil, _field), do: {:ok, nil}
  def decode("", _field), do: {:ok, ""}

  def decode(value, field) when is_binary(value) and field in @secret_fields do
    with {:ok, module, options} <- configured() do
      module.decode(value, %{field: field}, options)
    end
  end

  @spec encoded?(String.t() | nil) :: boolean()
  def encoded?(value) when is_binary(value) do
    case configured() do
      {:ok, module, options} -> module.encoded?(value, options)
      {:error, _reason} -> false
    end
  end

  def encoded?(_value), do: false

  @spec encode_attrs(map()) :: {:ok, map()} | {:error, term()}
  def encode_attrs(attrs) when is_map(attrs) do
    Enum.reduce_while(@secret_fields, {:ok, attrs}, fn field, {:ok, encoded} ->
      encode_attr(encoded, field)
    end)
  end

  defp encode_attr(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> put_encoded_attr(attrs, field, value)
      :error -> {:cont, {:ok, attrs}}
    end
  end

  defp put_encoded_attr(attrs, field, value) do
    case encode(value, field) do
      {:ok, encoded} -> {:cont, {:ok, Map.put(attrs, field, encoded)}}
      {:error, reason} -> {:halt, {:error, {:provider_token_codec, reason}}}
    end
  end

  @spec credential(ProviderToken.t()) :: {:ok, ProviderCredential.t()} | {:error, term()}
  def credential(%ProviderToken{} = stored) do
    with {:ok, token} <- decode(stored.token, :token),
         {:ok, refresh_token} <- decode(stored.refresh_token, :refresh_token) do
      {:ok,
       struct!(ProviderCredential, %{
         id: stored.id,
         provider: stored.provider,
         kind: stored.kind,
         token: token,
         label: stored.label,
         proxy: stored.proxy,
         refresh_token: refresh_token,
         expires_at: stored.expires_at,
         account_id: stored.account_id,
         enabled: stored.enabled,
         added_at: stored.added_at
       })}
    else
      {:error, reason} -> {:error, {:provider_token_codec, reason}}
    end
  end

  @doc false
  @spec for_provider(ProviderToken.t()) ::
          {:ok, ProviderCredential.t() | ProviderToken.t()} | {:error, term()}
  def for_provider(%ProviderToken{} = stored) do
    case configured() do
      {:ok, LLMProxy.ProviderTokenCodec.Plaintext, _options} -> {:ok, stored}
      {:ok, _module, _options} -> credential(stored)
      {:error, reason} -> {:error, {:provider_token_codec, reason}}
    end
  end

  @doc false
  @spec configured() :: {:ok, module(), options()} | {:error, term()}
  def configured do
    case LLMProxy.Config.provider_token_codec() do
      {module, options} when is_atom(module) and (is_list(options) or is_map(options)) ->
        validate_codec(module, options)

      module when is_atom(module) ->
        validate_codec(module, [])

      _other ->
        {:error, :invalid_codec_configuration}
    end
  end

  defp validate_codec(module, options) do
    if Code.ensure_loaded?(module) and function_exported?(module, :encode, 3) and
         function_exported?(module, :decode, 3) and
         function_exported?(module, :encoded?, 2) do
      {:ok, module, options}
    else
      {:error, :invalid_codec_module}
    end
  end
end
