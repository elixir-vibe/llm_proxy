defmodule LLMProxy.Provider.TokenCodec do
  @moduledoc """
  Configurable encoding boundary for provider API keys and OAuth tokens.

  A codec receives the credential field as context. This lets a codec bind its
  ciphertext to the field and prevents an access token from being used as a
  refresh token. Configure a module or a `{module, options}` tuple with
  `:provider_token_codec`.
  """

  alias LLMProxy.Provider.Credential
  alias LLMProxy.Schemas.ProviderToken

  @type context :: %{required(:field) => :token | :refresh_token}
  @type options :: keyword() | map()

  @callback encode(String.t(), context(), options()) ::
              {:ok, String.t()} | {:error, term()}
  @callback decode(String.t(), context(), options()) ::
              {:ok, String.t()} | {:error, term()}
  @callback encoded?(String.t(), options()) :: boolean()
  @callback validate_options(options()) :: :ok | {:error, term()}

  @optional_callbacks validate_options: 1

  @secret_fields [:token, :refresh_token]
  @built_in_envelope_prefix "llm_proxy:token:"
  @safe_codec_errors [
    :authentication_failed,
    :decryption_failed,
    :encrypted_value_requires_keyring,
    :encryption_failed,
    :invalid_ciphertext,
    :invalid_key,
    :plaintext_not_allowed,
    :unknown_key_id
  ]

  @spec encode(String.t() | nil, :token | :refresh_token) ::
          {:ok, String.t() | nil} | {:error, term()}
  def encode(nil, _field), do: {:ok, nil}
  def encode("", _field), do: {:ok, ""}

  def encode(value, field) when is_binary(value) and field in @secret_fields do
    with {:ok, module, options} <- configured() do
      invoke_codec(module, :encode, [value, %{field: field}, options])
    end
  end

  @spec decode(String.t() | nil, :token | :refresh_token) ::
          {:ok, String.t() | nil} | {:error, term()}
  def decode(nil, _field), do: {:ok, nil}
  def decode("", _field), do: {:ok, ""}

  def decode(value, field) when is_binary(value) and field in @secret_fields do
    with {:ok, module, options} <- configured() do
      invoke_codec(module, :decode, [value, %{field: field}, options])
    end
  end

  @spec encoded?(String.t() | nil) :: boolean()
  def encoded?(value) when is_binary(value) do
    built_in_envelope?(value) or configured_encoded?(value)
  end

  def encoded?(_value), do: false

  @doc false
  @spec built_in_envelope?(term()) :: boolean()
  def built_in_envelope?(value) when is_binary(value),
    do: String.starts_with?(value, @built_in_envelope_prefix)

  def built_in_envelope?(_value), do: false

  @spec encode_attrs(map()) :: {:ok, map()} | {:error, term()}
  def encode_attrs(attrs) when is_map(attrs) do
    Enum.reduce_while(@secret_fields, {:ok, attrs}, fn field, {:ok, encoded} ->
      encode_attr(encoded, field)
    end)
  end

  @spec credential(ProviderToken.t()) :: {:ok, Credential.t()} | {:error, term()}
  def credential(%ProviderToken{} = stored) do
    with {:ok, token} <- decode(stored.token, :token),
         {:ok, refresh_token} <- decode(stored.refresh_token, :refresh_token) do
      {:ok,
       struct!(Credential, %{
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
  @spec for_provider(ProviderToken.t()) :: {:ok, Credential.t()} | {:error, term()}
  def for_provider(%ProviderToken{} = stored), do: credential(stored)

  @doc false
  @spec validate_configuration() :: :ok | {:error, atom()}
  def validate_configuration do
    case configured() do
      {:ok, _module, _options} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec configured() :: {:ok, module(), options()} | {:error, atom()}
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

  defp configured_encoded?(value) do
    case configured() do
      {:ok, module, options} -> invoke_encoded?(module, value, options)
      {:error, _reason} -> false
    end
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

  defp validate_codec(module, options) do
    if codec_module?(module) do
      validate_codec_options(module, options)
    else
      {:error, :invalid_codec_module}
    end
  end

  defp codec_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :encode, 3) and
      function_exported?(module, :decode, 3) and function_exported?(module, :encoded?, 2)
  end

  defp validate_codec_options(module, options) do
    if function_exported?(module, :validate_options, 1) do
      try do
        case module.validate_options(options) do
          :ok -> {:ok, module, options}
          _other -> {:error, :invalid_codec_options}
        end
      catch
        _kind, _reason -> {:error, :invalid_codec_options}
      end
    else
      {:ok, module, options}
    end
  end

  defp invoke_codec(module, function, arguments) do
    case apply(module, function, arguments) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:error, reason} when reason in @safe_codec_errors -> {:error, reason}
      {:error, _reason} -> {:error, :codec_failed}
      _other -> {:error, :codec_failed}
    end
  catch
    _kind, _reason -> {:error, :codec_failed}
  end

  defp invoke_encoded?(module, value, options) do
    module.encoded?(value, options) == true
  catch
    _kind, _reason -> false
  end
end
