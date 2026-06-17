defmodule Mix.Tasks.LlmProxy.ReleaseArtifact do
  @moduledoc """
  Builds a built-in Mix release tarball and writes a HostKit-readable ETF manifest.

      MIX_ENV=prod mix llm_proxy.release_artifact

  Options:

    * `--release` - Mix release name, defaults to `llm_proxy`
    * `--version` - artifact version, defaults to current git short SHA
    * `--output-dir` - artifact directory, defaults to `_build/prod/artifacts`
    * `--manifest` - ETF manifest path, defaults to `<output-dir>/<release>.etf`
    * `--health-path` - health check path, defaults to `/health`
    * `--health-port` - health check port, defaults to `4000`
    * `--skip-assets` - do not run `mix assets.deploy`
    * `--skip-build` - do not run `mix release`, only package existing release dir
  """

  use Mix.Task

  alias LLMProxy.ReleaseArtifact

  @shortdoc "Builds release tarball and ETF artifact manifest"

  @switches [
    release: :string,
    version: :string,
    output_dir: :string,
    manifest: :string,
    health_path: :string,
    health_port: :integer,
    skip_assets: :boolean,
    skip_build: :boolean
  ]

  @impl true
  def run(args) do
    {parsed, _rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    opts = ReleaseArtifact.default_opts(parsed)

    unless Keyword.get(parsed, :skip_build, false) do
      ensure_prod!()
      maybe_run_assets(parsed)
      Mix.Task.run("release", [Keyword.fetch!(opts, :release), "--overwrite"])
    end

    tarball = ReleaseArtifact.create_tarball!(opts)
    manifest = ReleaseArtifact.write_manifest!(opts)

    Mix.shell().info("Release tarball: #{tarball}")
    Mix.shell().info("Artifact manifest: #{manifest}")
  end

  defp ensure_prod! do
    unless Mix.env() == :prod do
      Mix.raise(
        "llm_proxy.release_artifact must run with MIX_ENV=prod unless --skip-build is set"
      )
    end
  end

  defp maybe_run_assets(opts) do
    unless Keyword.get(opts, :skip_assets, false) do
      if Mix.Task.get("assets.deploy") do
        Mix.Task.run("assets.deploy")
      end
    end
  end
end
