defmodule LLMProxy.ReleaseArtifactTest do
  use ExUnit.Case, async: true

  alias LLMProxy.ReleaseArtifact

  test "builds HostKit-readable BEAM release artifact manifest" do
    opts =
      ReleaseArtifact.default_opts(
        release: :demo_app,
        app: :demo_app,
        version: "abc123",
        mix_env: :prod,
        output_dir: tmp_path("artifacts"),
        health_path: "/ready",
        health_port: 4100,
        env_clear: %{"PHX_HOST" => "app.example.com"},
        env_secret: ["SECRET_KEY_BASE"]
      )

    manifest = ReleaseArtifact.manifest(opts)

    assert manifest.tool == "llm_proxy"
    assert manifest.format == :beam_release_artifact
    assert manifest.format_version == 1
    assert manifest.app == "demo_app"
    assert manifest.release == "demo_app"
    assert manifest.version == "abc123"
    assert manifest.mix_env == "prod"
    assert manifest.runtime.command == ["bin/demo_app", "start"]

    assert manifest.health_check == %{
             path: "/ready",
             port: 4100,
             url: "http://127.0.0.1:4100/ready"
           }

    assert manifest.env == %{
             clear: %{"PHX_HOST" => "app.example.com"},
             secret: ["SECRET_KEY_BASE"]
           }

    assert String.ends_with?(manifest.tarball, "demo_app-abc123.tar.gz")
  end

  test "writes and safely reads ETF manifest" do
    manifest_path = tmp_path("artifact.etf")

    opts =
      ReleaseArtifact.default_opts(
        release: :demo_app,
        app: :demo_app,
        version: "abc123",
        mix_env: :test,
        output_dir: tmp_path("artifacts"),
        manifest: manifest_path
      )

    assert ReleaseArtifact.write_manifest!(opts) == Path.expand(manifest_path)
    assert ReleaseArtifact.read_manifest!(manifest_path) == ReleaseArtifact.manifest(opts)
  end

  test "creates compressed tarball from built release directory" do
    release_dir = Path.join(["_build", "test", "rel", "demo_app"])
    File.rm_rf!(release_dir)
    File.mkdir_p!(Path.join(release_dir, "bin"))
    File.mkdir_p!(Path.join(release_dir, "lib/demo_app-0.1.0/ebin"))
    File.write!(Path.join(release_dir, "bin/demo_app"), "#!/bin/sh\n")
    File.write!(Path.join(release_dir, "lib/demo_app-0.1.0/ebin/demo.app"), "[]")

    opts =
      ReleaseArtifact.default_opts(
        release: :demo_app,
        app: :demo_app,
        version: "abc123",
        mix_env: :test,
        output_dir: tmp_path("artifacts")
      )

    tarball = ReleaseArtifact.create_tarball!(opts)
    assert File.exists?(tarball)

    assert {:ok, files} = :erl_tar.table(String.to_charlist(tarball), [:compressed])
    assert ~c"bin/demo_app" in files
    assert ~c"lib/demo_app-0.1.0/ebin/demo.app" in files
  after
    File.rm_rf!(Path.join(["_build", "test", "rel", "demo_app"]))
  end

  defp tmp_path(name) do
    Path.join([
      System.tmp_dir!(),
      "llm-proxy-release-artifact",
      to_string(System.unique_integer([:positive])),
      name
    ])
  end
end
