defmodule Mix.Tasks.LlmProxy.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "installer adds LLMProxy migration alias and missing ecto.setup alias" do
    igniter =
      test_project()
      |> Igniter.compose_task("llm_proxy.install", [])

    mix_exs = file_content(igniter, "mix.exs")

    assert mix_exs =~ "\"llm_proxy.migrate\":"

    assert mix_exs =~
             "\"ecto.migrate --migrations-path priv/repo/migrations --migrations-path deps/llm_proxy/priv/repo/migrations\""

    refute mix_exs =~
             "\"ecto.migrate --quiet --migrations-path priv/repo/migrations --migrations-path deps/llm_proxy/priv/repo/migrations\""
  end

  test "installer updates existing default Ecto aliases without appending to custom aliases" do
    igniter =
      test_project(files: %{"mix.exs" => mix_exs_with_default_aliases()})
      |> Igniter.compose_task("llm_proxy.install", [])

    mix_exs = file_content(igniter, "mix.exs")

    refute mix_exs =~ "\"ecto.migrate\","
    refute mix_exs =~ "\"ecto.migrate --quiet\","

    assert mix_exs =~
             "\"ecto.migrate --migrations-path priv/repo/migrations --migrations-path deps/llm_proxy/priv/repo/migrations\""

    assert mix_exs =~
             "\"ecto.migrate --quiet --migrations-path priv/repo/migrations --migrations-path deps/llm_proxy/priv/repo/migrations\""
  end

  test "installer leaves custom test aliases without default migration step unchanged" do
    igniter =
      test_project(files: %{"mix.exs" => mix_exs_with_custom_test_alias()})
      |> Igniter.compose_task("llm_proxy.install", [])

    mix_exs = file_content(igniter, "mix.exs")

    assert mix_exs =~ "test: [\"test --only integration\"]"

    refute mix_exs =~
             "\"test --only integration\",\n        \"ecto.migrate --quiet --migrations-path priv/repo/migrations --migrations-path deps/llm_proxy/priv/repo/migrations\""
  end

  defp file_content(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end

  defp mix_exs_with_custom_test_alias do
    """
    defmodule Test.MixProject do
      use Mix.Project

      def project do
        [
          app: :test,
          version: "0.1.0",
          elixir: "~> 1.17",
          aliases: aliases(),
          deps: deps()
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end

      defp deps do
        []
      end

      defp aliases do
        [
          test: ["test --only integration"]
        ]
      end
    end
    """
  end

  defp mix_exs_with_default_aliases do
    """
    defmodule Test.MixProject do
      use Mix.Project

      def project do
        [
          app: :test,
          version: "0.1.0",
          elixir: "~> 1.17",
          aliases: aliases(),
          deps: deps()
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end

      defp deps do
        []
      end

      defp aliases do
        [
          "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
          "ecto.reset": ["ecto.drop", "ecto.setup"],
          test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
        ]
      end
    end
    """
  end
end
