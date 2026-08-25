defmodule LLMProxy.Config.Provider do
  @moduledoc """
  Release config provider for strict standalone LLMProxy TOML configuration.

  This provider is intended for the standalone OTP release and merges server,
  storage, routing, telemetry, provider, and model data. It is no-op when the
  configured TOML file is absent, so embedding applications remain configured
  through ordinary Elixir application configuration.
  """

  @behaviour Config.Provider

  alias LLMProxy.Config.TOML

  @default_path "/etc/llm-proxy/config.toml"

  @type state :: [path: Config.Provider.config_path()]

  @impl true
  def init(opts) when is_list(opts) do
    [path: Keyword.get(opts, :path, {:system, "LLM_PROXY_CONFIG_TOML", @default_path})]
  end

  @impl true
  def load(config, opts) when is_list(opts) do
    {:ok, _apps} = Application.ensure_all_started(:toml)

    path = opts |> Keyword.fetch!(:path) |> resolve_path()

    if File.regular?(path) do
      Config.Reader.merge(config, load_toml!(path))
    else
      config
    end
  end

  defp resolve_path({:system, env, default}) do
    System.get_env(env, default)
  end

  defp resolve_path(path), do: Config.Provider.resolve_config_path!(path)

  defp load_toml!(path) do
    case TOML.decode_file(path) do
      {:ok, config} ->
        config

      {:error, _reason} ->
        raise ArgumentError, "invalid LLMProxy TOML config #{path}"
    end
  end
end
