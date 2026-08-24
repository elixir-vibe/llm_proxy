defmodule LLMProxy.Provider.TokenCodec.AESGCM do
  @moduledoc """
  Versioned AES-256-GCM codec for provider credentials.

  Options must contain `:active_key_id` and a `:keys` map. Each key is a
  Base64-encoded 32-byte value or an explicit `{:raw, value}` tuple. Encryption
  always uses the active key. Decryption selects the key ID from the ciphertext,
  so old keys can stay in the map during rotation.

  Set `:allow_plaintext` to `false` after an explicit migration is verified.
  """

  @behaviour LLMProxy.Provider.TokenCodec

  @prefix "llm_proxy:token:v1:"
  @nonce_bytes 12
  @tag_bytes 16
  @key_bytes 32

  @impl true
  def validate_options(options) do
    with {:ok, active_key_id} <- active_key_id(options),
         {:ok, keys} <- keys(options),
         :ok <- validate_keys(keys),
         {:ok, _active_key} <- keys |> find_key(active_key_id) |> normalize_key() do
      validate_allow_plaintext(options)
    end
  end

  @impl true
  def encode(value, %{field: field}, options) do
    with {:ok, active_key_id} <- active_key_id(options),
         {:ok, key} <- key(options, active_key_id) do
      nonce = :crypto.strong_rand_bytes(@nonce_bytes)
      {ciphertext, tag} = encrypt(key, nonce, value, aad(field, active_key_id))
      payload = Base.url_encode64(nonce <> tag <> ciphertext, padding: false)
      {:ok, @prefix <> active_key_id <> ":" <> payload}
    end
  rescue
    _error in [ArgumentError] -> {:error, :encryption_failed}
  end

  @impl true
  def decode(value, %{field: field}, options) do
    if encoded?(value, options) do
      decode_ciphertext(value, field, options)
    else
      decode_plaintext(value, options)
    end
  end

  @impl true
  def encoded?(value, _options), do: String.starts_with?(value, @prefix)

  defp decode_ciphertext(value, field, options) do
    with {:ok, key_id, payload} <- split_envelope(value),
         {:ok, key} <- key(options, key_id),
         {:ok, packed} <- Base.url_decode64(payload, padding: false),
         {:ok, nonce, tag, ciphertext} <- split_payload(packed),
         plaintext when is_binary(plaintext) <-
           decrypt(key, nonce, ciphertext, aad(field, key_id), tag) do
      {:ok, plaintext}
    else
      :error -> {:error, :authentication_failed}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error in [ArgumentError] -> {:error, :decryption_failed}
  end

  defp decode_plaintext(value, options) do
    if option(options, :allow_plaintext, true) do
      {:ok, value}
    else
      {:error, :plaintext_not_allowed}
    end
  end

  defp split_envelope(@prefix <> envelope) do
    case String.split(envelope, ":", parts: 2) do
      [key_id, payload] when key_id != "" and payload != "" -> {:ok, key_id, payload}
      _other -> {:error, :invalid_ciphertext}
    end
  end

  defp split_payload(
         <<nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>
       ),
       do: {:ok, nonce, tag, ciphertext}

  defp split_payload(_payload), do: {:error, :invalid_ciphertext}

  defp active_key_id(options) do
    case option(options, :active_key_id) do
      key_id when is_binary(key_id) and key_id != "" -> validate_key_id(key_id)
      _other -> {:error, :missing_active_key_id}
    end
  end

  defp keys(options) do
    case option(options, :keys) do
      keys when is_map(keys) and map_size(keys) > 0 -> {:ok, keys}
      _other -> {:error, :invalid_keys}
    end
  end

  defp validate_keys(keys) do
    Enum.reduce_while(keys, :ok, fn {key_id, value}, :ok ->
      with {:ok, _normalized_key_id} <- normalized_key_id(key_id),
           {:ok, _key} <- normalize_key(value) do
        {:cont, :ok}
      else
        _error -> {:halt, {:error, :invalid_keyring}}
      end
    end)
  end

  defp normalized_key_id(key_id) when is_binary(key_id), do: validate_key_id(key_id)

  defp normalized_key_id(key_id) when is_atom(key_id),
    do: key_id |> Atom.to_string() |> validate_key_id()

  defp normalized_key_id(_key_id), do: {:error, :invalid_key_id}

  defp validate_key_id(key_id) do
    if Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, key_id) do
      {:ok, key_id}
    else
      {:error, :invalid_active_key_id}
    end
  end

  defp validate_allow_plaintext(options) do
    if is_boolean(option(options, :allow_plaintext, true)) do
      :ok
    else
      {:error, :invalid_allow_plaintext}
    end
  end

  defp key(options, key_id) do
    options
    |> option(:keys, %{})
    |> find_key(key_id)
    |> normalize_key()
  end

  defp find_key(keys, key_id) when is_map(keys) do
    Map.get(keys, key_id) || find_atom_key(keys, key_id)
  end

  defp find_key(_keys, _key_id), do: nil

  defp find_atom_key(keys, key_id) do
    Enum.find_value(keys, fn
      {candidate, value} when is_atom(candidate) ->
        if Atom.to_string(candidate) == key_id, do: value

      _entry ->
        nil
    end)
  end

  defp normalize_key({:raw, key}) when is_binary(key) and byte_size(key) == @key_bytes,
    do: {:ok, key}

  defp normalize_key(key) when is_binary(key) do
    case Base.decode64(key) do
      {:ok, decoded} when byte_size(decoded) == @key_bytes -> {:ok, decoded}
      _other -> {:error, :invalid_key}
    end
  end

  defp normalize_key(nil), do: {:error, :unknown_key_id}
  defp normalize_key(_key), do: {:error, :invalid_key}

  defp option(options, key, default \\ nil)
  defp option(options, key, default) when is_list(options), do: Keyword.get(options, key, default)
  defp option(options, key, default) when is_map(options), do: Map.get(options, key, default)

  defp aad(field, key_id),
    do: "llm_proxy.provider_token." <> Atom.to_string(field) <> "." <> key_id

  defp encrypt(key, nonce, plaintext, aad) do
    :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad, @tag_bytes, true)
  end

  defp decrypt(key, nonce, ciphertext, aad, tag) do
    :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, aad, tag, false)
  end
end
