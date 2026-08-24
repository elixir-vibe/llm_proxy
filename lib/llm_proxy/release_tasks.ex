defmodule LLMProxy.ReleaseTasks do
  @moduledoc """
  Release-safe operational tasks for standalone LLMProxy deployments.

  These functions are intended to be called through `bin/llm_proxy eval ...`
  by systemd jobs or operators. Release `eval` runs in a new, non-booted VM,
  so tasks that need bundled storage start only the local dependencies they use.
  """

  alias LLMProxy.Providers.OpenAICodex.OAuth
  alias LLMProxy.Providers.OpenAICodex.OAuth.Login, as: CodexLogin
  alias LLMProxy.Storage.QuackDBServer
  alias LLMProxy.Storage.Repo

  @doc "Runs all pending Ecto migrations for the configured LLMProxy repo."
  @spec migrate() :: :ok
  def migrate do
    repo = LLMProxy.Config.repo()
    migration_source = Application.app_dir(:llm_proxy, "priv/repo/migrations")

    with_quackdb_server(fn ->
      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(repo, fn started_repo ->
          migrations = Ecto.Migrator.run(started_repo, migration_source, :up, all: true)
          checkpoint_if_quackdb(started_repo)
          migrations
        end)
    end)

    :ok
  end

  @doc "Print provider-token encryption state without credential values."
  @spec provider_tokens_status() :: :ok
  def provider_tokens_status do
    run_provider_token_operation(:status)
  end

  @doc "Verify that the configured codec can read all provider tokens."
  @spec provider_tokens_verify() :: :ok
  def provider_tokens_verify do
    run_provider_token_operation(:verify)
  end

  @doc "Encrypt plaintext provider tokens with the active codec key."
  @spec provider_tokens_encrypt() :: :ok
  def provider_tokens_encrypt do
    run_provider_token_operation(:encrypt_all)
  end

  @doc "Re-encrypt all provider tokens with the active codec key."
  @spec provider_tokens_rotate() :: :ok
  def provider_tokens_rotate do
    run_provider_token_operation(:rotate_all)
  end

  @doc "Restore provider tokens to plaintext for a controlled rollback."
  @spec provider_tokens_decrypt() :: :ok
  def provider_tokens_decrypt do
    run_provider_token_operation(:decrypt_all)
  end

  @doc "Start deployment drain mode on the running LLMProxy service."
  @spec drain_start() :: :ok
  def drain_start do
    {:ok, status} = ops_call({LLMProxy.Ops, :drain_start})
    IO.puts("LLMProxy drain started: #{inspect(status)}")
    :ok
  end

  @doc "Cancel deployment drain mode on the running LLMProxy service."
  @spec drain_cancel() :: :ok
  def drain_cancel do
    {:ok, status} = ops_call({LLMProxy.Ops, :drain_cancel})
    IO.puts("LLMProxy drain canceled: #{inspect(status)}")
    :ok
  end

  @doc "Print deployment drain status from the running LLMProxy service."
  @spec drain_status() :: :ok
  def drain_status do
    {:ok, status} = ops_call({LLMProxy.Ops, :drain_status})
    IO.puts(inspect(status, pretty: true))
    :ok
  end

  @doc "Drain active work before deployment, restoring service on failure."
  @spec drain_for_deploy(timeout()) :: :ok
  def drain_for_deploy(timeout_ms \\ 1_800_000) do
    drain_start()

    try do
      drain_await(timeout_ms)
    catch
      kind, reason ->
        cancel_drain_after_failure()
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc "Wait for active work on the running LLMProxy service to reach zero."
  @spec drain_await(timeout()) :: :ok
  def drain_await(timeout_ms \\ 1_800_000) do
    case ops_call({LLMProxy.Ops, :drain_await}, %{timeout_ms: timeout_ms},
           timeout: timeout_ms + 1_000
         ) do
      :ok -> :ok
      {:error, :timeout} -> raise "LLMProxy drain timed out after #{timeout_ms}ms"
      {:error, reason} -> raise "LLMProxy drain failed: #{inspect(reason)}"
    end
  end

  @doc "Runs an interactive OpenAI Codex OAuth login and stores the provider token."
  @spec codex_login([String.t()]) :: :ok
  def codex_login(argv \\ []) do
    if "--help" in argv or "-h" in argv do
      print_codex_login_help()
    else
      run_codex_login()
    end
  end

  defp ops_call(op, payload \\ %{}, opts \\ []) do
    socket =
      LLMProxy.Config.rpc_socket() || System.get_env("LLM_PROXY_RPC_SOCKET") ||
        raise "LLM_PROXY_RPC_SOCKET is not configured"

    with :ok <- SafeRPC.Atoms.prepare(LLMProxy.Ops.client_atoms()),
         :ok <- SafeRPC.prepare(socket) do
      SafeRPC.call(socket, op, payload, opts)
    end
  end

  defp cancel_drain_after_failure do
    drain_cancel()
  catch
    _kind, _reason -> :ok
  end

  defp run_codex_login do
    ensure_http_client_started()

    verifier = CodexLogin.new_verifier()
    state = CodexLogin.new_state()
    challenge = CodexLogin.pkce_challenge(verifier)
    url = CodexLogin.authorize_url(challenge, state)

    IO.puts("Open this URL to sign in with ChatGPT/Codex:\n\n#{url}\n")
    IO.puts("After login, paste the final redirect URL or authorization code.")

    with input when is_binary(input) <- IO.gets("Codex redirect URL/code: "),
         {:ok, code} <- CodexLogin.parse_authorization_input(input, state),
         {:ok, credentials} <- CodexLogin.exchange_code(code, verifier),
         {:ok, token} <- store_codex_credentials(credentials) do
      IO.puts("Connected OpenAI Codex account #{account_label(token.account_id)}.")
      :ok
    else
      nil ->
        IO.puts(:stderr, "Codex sign-in failed: no authorization code provided")
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Codex sign-in failed: #{inspect(reason, pretty: true)}")
        :ok
    end
  end

  defp store_codex_credentials(%OAuth{} = credentials) do
    with_repo(fn ->
      LLMProxy.Storage.add_token("openai-codex", "oauth", credentials.access, %{
        refresh_token: credentials.refresh,
        expires_at: credentials.expires_at,
        account_id: credentials.account_id,
        label: "codex-login"
      })
    end)
  end

  defp run_provider_token_operation(operation) do
    result =
      with_repo(fn ->
        apply(LLMProxy.Provider.TokenCodec.Migration, operation, [])
      end)

    case result do
      {:ok, counts} ->
        IO.puts("Provider token operation complete: #{inspect(counts)}")
        :ok

      {:error, _reason} ->
        raise "provider token operation failed"
    end
  end

  defp with_repo(fun) do
    repo = LLMProxy.Config.repo()

    with_quackdb_server(fn ->
      {:ok, result, _apps} =
        Ecto.Migrator.with_repo(repo, fn started_repo ->
          result = fun.()
          checkpoint_if_quackdb(started_repo)
          result
        end)

      result
    end)
  end

  @doc false
  @spec ensure_http_client_started() :: :ok
  def ensure_http_client_started do
    {:ok, _apps} = Application.ensure_all_started(:req)
    :ok
  end

  defp print_codex_login_help do
    IO.puts("""
    Usage: codex_login

    Starts an interactive ChatGPT/Codex OAuth login for standalone LLMProxy.
    Open the printed URL in a browser, then paste the final redirect URL or
    authorization code back into this prompt. The resulting OAuth token is
    stored in provider_tokens for provider openai-codex, kind oauth.
    """)

    :ok
  end

  defp account_label(nil), do: "(unknown account)"
  defp account_label(account_id), do: account_id

  defp checkpoint_if_quackdb(repo) do
    if Repo.adapter() == Ecto.Adapters.QuackDB do
      repo.query!("CHECKPOINT")
    end

    :ok
  end

  defp with_quackdb_server(fun) do
    if Repo.adapter() == Ecto.Adapters.QuackDB do
      run_with_temporary_quackdb_server(fun)
    else
      fun.()
    end
  end

  defp run_with_temporary_quackdb_server(fun) do
    case QuackDBServer.start_link(LLMProxy.Config.quackdb_server_options()) do
      {:ok, pid} ->
        try do
          fun.()
        after
          if Process.alive?(pid), do: GenServer.stop(pid)
        end

      {:error, _reason} ->
        fun.()
    end
  end
end
