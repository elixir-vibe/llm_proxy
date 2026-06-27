defmodule LLMProxy.Config.Provider do
  @moduledoc """
  Release config provider for optional standalone LLMProxy TOML config.

  This provider is intended for the standalone OTP release. It is no-op when the
  configured TOML file is absent, so embedding applications are unaffected and
  continue to use normal `config :llm_proxy` application configuration.
  """

  @behaviour Config.Provider

  @default_path "/etc/llm-proxy/config.toml"

  @type state :: [path: Config.Provider.config_path()]

  @impl true
  def init(opts) when is_list(opts) do
    [path: Keyword.get(opts, :path, {:system, "LLM_PROXY_CONFIG_TOML", @default_path})]
  end

  @impl true
  def load(config, opts) when is_list(opts) do
    {:ok, _apps} = Application.ensure_all_started(:toml)

    path = opts |> Keyword.fetch!(:path) |> Config.Provider.resolve_config_path!()

    if File.regular?(path) do
      Config.Reader.merge(config, llm_proxy: load_toml!(path))
    else
      config
    end
  end

  defp load_toml!(path) do
    case LLMProxy.Config.TOML.decode_file(path) do
      {:ok, config} ->
        config

      {:error, reason} ->
        raise ArgumentError, "invalid LLMProxy TOML config #{path}: #{inspect(reason)}"
    end
  end
end
