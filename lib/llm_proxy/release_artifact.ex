defmodule LLMProxy.ReleaseArtifact do
  @moduledoc """
  Builds BEAM-native release artifact manifests for HostKit-managed deployments.

  This module intentionally uses the built-in Mix release layout plus a tarball
  and ETF manifest. It does not own SSH, systemd, Caddy, rollback, or server
  mutation.
  """

  @format :beam_release_artifact
  @format_version 1

  @type build_opts :: [
          release: String.t(),
          app: String.t(),
          version: String.t(),
          mix_env: String.t(),
          output_dir: Path.t(),
          manifest: Path.t(),
          health_path: String.t(),
          health_port: non_neg_integer(),
          env_clear: %{String.t() => String.t()},
          env_secret: [String.t()]
        ]

  @type manifest :: %{
          required(:tool) => String.t(),
          required(:format) => :beam_release_artifact,
          required(:format_version) => pos_integer(),
          required(:app) => String.t(),
          required(:release) => String.t(),
          required(:version) => String.t(),
          required(:mix_env) => String.t(),
          required(:tarball) => String.t(),
          required(:runtime) => map(),
          required(:env) => map(),
          required(:health_check) => map()
        }

  @spec default_opts(keyword()) :: build_opts()
  def default_opts(overrides \\ []) do
    release = Keyword.get(overrides, :release, :llm_proxy) |> normalize_name(:release)
    app = Keyword.get(overrides, :app, :llm_proxy) |> normalize_name(:app)
    mix_env = Keyword.get(overrides, :mix_env, :prod) |> normalize_name(:mix_env)
    version = Keyword.get(overrides, :version, git_version())
    output_dir = Keyword.get(overrides, :output_dir, "_build/#{mix_env}/artifacts")
    manifest = Keyword.get(overrides, :manifest, Path.join(output_dir, "#{release}.etf"))

    [
      release: release,
      app: app,
      version: version,
      mix_env: mix_env,
      output_dir: output_dir,
      manifest: manifest,
      health_path: Keyword.get(overrides, :health_path, "/health"),
      health_port: Keyword.get(overrides, :health_port, 4000),
      env_clear: Keyword.get(overrides, :env_clear, %{}),
      env_secret: Keyword.get(overrides, :env_secret, [])
    ]
  end

  @spec release_dir(build_opts()) :: String.t()
  def release_dir(opts) do
    release = Keyword.fetch!(opts, :release)
    mix_env = Keyword.fetch!(opts, :mix_env)
    Path.join(["_build", mix_env, "rel", release])
  end

  @spec tarball_path(build_opts()) :: String.t()
  def tarball_path(opts) do
    release = Keyword.fetch!(opts, :release)
    version = Keyword.fetch!(opts, :version)
    output_dir = Keyword.fetch!(opts, :output_dir)
    Path.join(output_dir, "#{release}-#{version}.tar.gz")
  end

  @spec manifest(build_opts()) :: manifest()
  def manifest(opts) do
    release = Keyword.fetch!(opts, :release)
    app = Keyword.fetch!(opts, :app)
    mix_env = Keyword.fetch!(opts, :mix_env)
    health_port = Keyword.fetch!(opts, :health_port)
    health_path = Keyword.fetch!(opts, :health_path)

    %{
      tool: "llm_proxy",
      format: @format,
      format_version: @format_version,
      app: app,
      release: release,
      version: Keyword.fetch!(opts, :version),
      mix_env: mix_env,
      tarball: Path.expand(tarball_path(opts)),
      runtime: %{
        command: ["bin/#{release}", "start"]
      },
      env: %{
        clear: Keyword.fetch!(opts, :env_clear),
        secret: Keyword.fetch!(opts, :env_secret)
      },
      health_check: %{
        path: health_path,
        port: health_port,
        url: "http://127.0.0.1:#{health_port}#{health_path}"
      }
    }
  end

  @spec create_tarball!(build_opts()) :: String.t()
  def create_tarball!(opts) do
    source = release_dir(opts)
    target = tarball_path(opts)
    File.mkdir_p!(Path.dirname(target))

    unless File.dir?(source) do
      raise ArgumentError, "release directory does not exist: #{source}"
    end

    target_charlist = String.to_charlist(target)
    {:ok, tar} = :erl_tar.open(target_charlist, [:write, :compressed])

    try do
      source
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.reject(&File.dir?/1)
      |> Enum.each(fn path ->
        :ok =
          :erl_tar.add(
            tar,
            String.to_charlist(path),
            path |> Path.relative_to(source) |> String.to_charlist(),
            []
          )
      end)
    after
      :ok = :erl_tar.close(tar)
    end

    Path.expand(target)
  end

  @spec write_manifest!(build_opts()) :: String.t()
  def write_manifest!(opts) do
    path = Keyword.fetch!(opts, :manifest)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(manifest(opts)))
    Path.expand(path)
  end

  @spec read_manifest!(Path.t()) :: manifest()
  def read_manifest!(path) do
    path
    |> File.read!()
    |> :erlang.binary_to_term([:safe])
  end

  @spec git_version() :: String.t()
  def git_version do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {version, 0} -> String.trim(version)
      {_output, _status} -> Mix.Project.config()[:version] || "dev"
    end
  end

  defp normalize_name(value, _name) when is_atom(value), do: Atom.to_string(value)
  defp normalize_name(value, _name) when is_binary(value), do: value
end
