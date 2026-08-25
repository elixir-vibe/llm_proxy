defmodule LLMProxy.ProviderUsage.Source do
  @moduledoc """
  Resolves provider-token records to qualified live usage sources.

  Codex is a built-in source. GLM sources come from named providers that use a
  Z.AI adapter or explicitly set `usage_adapter: "glm"`.
  """

  alias LLMProxy.ProviderUsage.Adapters.{Codex, GLM}
  alias LLMProxy.Schemas.ProviderToken

  @glm_adapters ~w(zai zai_coder zai_coding_plan)
  @default_glm_paths ["/api/monitor/usage/quota/limit", "/api/monitor/usage"]

  @derive {Inspect, except: [:stored_token]}
  @enforce_keys [
    :token_id,
    :stored_token,
    :adapter,
    :provider_label,
    :account_label,
    :usage_paths
  ]
  defstruct [
    :token_id,
    :stored_token,
    :adapter,
    :provider_label,
    :account_label,
    :base_url,
    :auth_scheme,
    :config_error,
    usage_paths: []
  ]

  @type t :: %__MODULE__{
          token_id: integer(),
          stored_token: ProviderToken.t(),
          adapter: module(),
          provider_label: String.t(),
          account_label: String.t(),
          base_url: String.t() | nil,
          usage_paths: [String.t()],
          auth_scheme: :raw | :bearer | nil,
          config_error: String.t() | nil
        }

  @spec accounts() :: [t()]
  def accounts do
    glm_sources = glm_sources()

    LLMProxy.Storage.list_tokens()
    |> Enum.flat_map(&source_for(&1, glm_sources))
    |> Enum.sort_by(& &1.token_id)
  end

  @spec supported_account?(integer()) :: boolean()
  def supported_account?(id) when is_integer(id) do
    Enum.any?(accounts(), &(&1.token_id == id))
  end

  def supported_account?(_id), do: false

  defp source_for(%ProviderToken{provider: "openai-codex", kind: "oauth"} = token, _glm) do
    base_url =
      "openai-codex"
      |> LLMProxy.Config.provider_value(:base_url)
      |> normalize_codex_base_url()

    [
      %__MODULE__{
        token_id: token.id,
        stored_token: token,
        adapter: Codex,
        provider_label: "OpenAI Codex",
        account_label: account_label(token),
        base_url: base_url,
        usage_paths: [codex_usage_path(base_url)],
        config_error: endpoint_or_source_error(token, codex_source_error(base_url))
      }
    ]
  end

  defp source_for(%ProviderToken{provider: pool, kind: "api-key"} = token, glm_sources) do
    case Map.get(glm_sources, pool) do
      nil -> []
      attrs -> [struct!(__MODULE__, Map.merge(attrs, account_attrs(token)))]
    end
  end

  defp source_for(_token, _glm_sources), do: []

  defp glm_sources do
    LLMProxy.Config.configured_providers()
    |> Enum.filter(fn {_name, config} -> glm_provider?(config) end)
    |> Enum.map(fn {name, config} -> {pool_name(Map.get(config, :token_pool, name)), config} end)
    |> Enum.reject(fn {pool, _config} -> is_nil(pool) end)
    |> Enum.group_by(fn {pool, _config} -> pool end)
    |> Map.new(fn {pool, providers} ->
      provider_configs = Enum.map(providers, fn {_pool, config} -> {pool, config} end)
      {pool, glm_source(provider_configs)}
    end)
  end

  defp glm_source(providers) do
    candidates =
      providers
      |> Enum.map(fn {_name, config} ->
        %{
          adapter: GLM,
          provider_label: "GLM Coding Plan",
          base_url: Map.get(config, :base_url),
          usage_paths: usage_paths(config),
          auth_scheme: auth_scheme(config)
        }
      end)
      |> Enum.uniq()

    case candidates do
      [candidate] -> Map.put(candidate, :config_error, source_error(candidate))
      [candidate | _rest] -> Map.put(candidate, :config_error, "Conflicting GLM usage sources")
    end
  end

  defp glm_provider?(config) do
    usage_adapter = Map.get(config, :usage_adapter)
    adapter = normalize_name(Map.get(config, :adapter))

    usage_adapter == "glm" or adapter in @glm_adapters
  end

  defp usage_paths(config), do: Map.get(config, :usage_paths, @default_glm_paths)

  defp auth_scheme(config) do
    case Map.get(config, :usage_auth_scheme, "raw") do
      "raw" -> :raw
      "bearer" -> :bearer
    end
  end

  defp source_error(%{base_url: base_url, usage_paths: paths, auth_scheme: auth_scheme}) do
    cond do
      not valid_base_url?(base_url) ->
        "GLM usage base URL is not a valid HTTPS URL"

      paths == [] or length(paths) > 3 or not Enum.all?(paths, &valid_path?/1) ->
        "GLM usage path is invalid"

      is_nil(auth_scheme) ->
        "GLM usage authorization scheme is invalid"

      true ->
        nil
    end
  end

  defp codex_source_error(base_url) do
    if valid_base_url?(base_url),
      do: nil,
      else: "Codex usage base URL is not a valid HTTPS URL"
  end

  defp codex_usage_path(base_url) when is_binary(base_url) do
    base_path = URI.parse(base_url).path || ""

    suffix =
      if String.contains?(base_path, "/backend-api"), do: "/wham/usage", else: "/api/codex/usage"

    String.trim_trailing(base_path, "/") <> suffix
  end

  defp codex_usage_path(_base_url), do: "/api/codex/usage"

  defp normalize_codex_base_url(base_url) when is_binary(base_url) do
    uri = URI.parse(base_url)
    path = String.trim_trailing(uri.path || "", "/")

    if uri.host in ["chatgpt.com", "chat.openai.com"] and
         not String.contains?(path, "/backend-api") do
      %{uri | path: path <> "/backend-api"} |> URI.to_string()
    else
      %{uri | path: path} |> URI.to_string()
    end
  end

  defp normalize_codex_base_url(base_url), do: base_url

  defp valid_base_url?(base_url) when is_binary(base_url) do
    match?(
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "",
      URI.parse(base_url)
    )
  end

  defp valid_base_url?(_base_url), do: false

  defp valid_path?(path) when is_binary(path) do
    byte_size(path) <= 256 and String.starts_with?(path, "/") and
      not String.starts_with?(path, "//") and
      not String.contains?(path, ["?", "#", "\\", "\r", "\n"])
  end

  defp valid_path?(_path), do: false

  defp account_attrs(%ProviderToken{} = token) do
    attrs = %{
      token_id: token.id,
      stored_token: token,
      account_label: account_label(token)
    }

    case endpoint_override_error(token) do
      nil -> attrs
      error -> Map.put(attrs, :config_error, error)
    end
  end

  defp endpoint_or_source_error(token, source_error) do
    endpoint_override_error(token) || source_error
  end

  defp endpoint_override_error(%ProviderToken{proxy: proxy})
       when is_binary(proxy) and proxy != "" do
    "Provider usage is unavailable for tokens with endpoint overrides"
  end

  defp endpoint_override_error(%ProviderToken{}), do: nil

  defp account_label(%ProviderToken{id: id, label: label}) do
    case safe_label(label) do
      nil -> "Account ##{id}"
      safe -> "#{redact_label(safe)} · ##{id}"
    end
  end

  defp safe_label(label) when is_binary(label) do
    label = String.trim(label)

    if String.length(label) <= 40 and Regex.match?(~r/^[[:alnum:]][[:alnum:] _.\-]*$/u, label) do
      label
    else
      nil
    end
  end

  defp safe_label(_label), do: nil

  defp redact_label(label) do
    characters = String.graphemes(label)
    "#{List.first(characters)}***#{List.last(characters)}"
  end

  defp normalize_name(nil), do: nil

  defp normalize_name(value) when not (is_binary(value) or is_atom(value)), do: nil

  defp normalize_name(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp pool_name(value) when is_binary(value), do: value
  defp pool_name(value) when is_atom(value), do: Atom.to_string(value)
  defp pool_name(_value), do: nil
end
