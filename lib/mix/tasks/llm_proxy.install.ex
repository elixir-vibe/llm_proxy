Code.ensure_compiled(Igniter)

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.LlmProxy.Install do
    @moduledoc """
    Installs LLMProxy embedder migration aliases into an existing Mix project.

    The installer keeps LLMProxy storage on normal Ecto migrations by adding
    aliases that include both the host application's migration directory and
    LLMProxy's dependency migration directory.
    """

    use Igniter.Mix.Task

    alias Igniter.Code.Common
    alias Igniter.Code.List, as: CodeList
    alias Igniter.Project.TaskAliases

    @example "mix igniter.install llm_proxy"
    @host_migrations_path "priv/repo/migrations"
    @llm_proxy_migrations_path "deps/llm_proxy/priv/repo/migrations"
    @migrate "ecto.migrate --migrations-path #{@host_migrations_path} --migrations-path #{@llm_proxy_migrations_path}"
    @migrate_quiet "ecto.migrate --quiet --migrations-path #{@host_migrations_path} --migrations-path #{@llm_proxy_migrations_path}"

    @shortdoc "Installs LLMProxy embedder migration aliases"

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :llm_proxy,
        installs: [],
        adds_deps: [],
        example: @example,
        positional: [],
        schema: [],
        defaults: [],
        aliases: [],
        required: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> TaskAliases.add_alias(:"llm_proxy.migrate", @migrate, if_exists: :ignore)
      |> TaskAliases.add_alias(:"ecto.setup", ecto_setup_alias(), if_exists: :ignore)
      |> TaskAliases.modify_existing_alias(
        :"ecto.setup",
        &replace_alias_step(&1, "ecto.migrate", @migrate)
      )
      |> TaskAliases.modify_existing_alias(
        :test,
        &replace_alias_step(&1, "ecto.migrate --quiet", @migrate_quiet)
      )
      |> Igniter.add_notice("""
      LLMProxy migrations are installed through Ecto migration paths.

      Use `mix llm_proxy.migrate` for host applications, or pass both migration
      directories to `Ecto.Migrator.run/4` in release migration code:

          priv/repo/migrations
          deps/llm_proxy/priv/repo/migrations
      """)
    end

    defp ecto_setup_alias do
      ["ecto.create", @migrate, "run priv/repo/seeds.exs"]
    end

    defp replace_alias_step(zipper, old_step, new_step) do
      CodeList.replace_in_list(zipper, &Common.nodes_equal?(&1, old_step), string_ast(new_step))
    end

    defp string_ast(value) do
      {:__block__, [trailing_comments: [], leading_comments: [], delimiter: "\""], [value]}
    end
  end
else
  defmodule Mix.Tasks.LlmProxy.Install do
    @moduledoc "Installs LLMProxy embedder migration aliases into an existing Mix project."
    @shortdoc @moduledoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'llm_proxy.install' requires igniter.

      Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
