defmodule LLMProxy.Admin.CodexOAuth do
  @moduledoc """
  Incant action callbacks for connecting OpenAI Codex OAuth accounts.

  These callbacks run inside the live LLMProxy service process, so token storage
  uses the already-running repo/QuackDB connection instead of starting release
  task storage in a second VM.
  """

  alias LLMProxy.Providers.OpenAICodex.OAuth
  alias LLMProxy.Providers.OpenAICodex.OAuth.Login, as: CodexLogin

  defmodule StartResult do
    @moduledoc "OpenAI Codex OAuth authorization details returned to the operator."

    use JSONCodec, fast_path: :json, strict: true

    @derive Jason.Encoder
    defstruct [:authorization_url, :state, :verifier]

    @type t :: %__MODULE__{
            authorization_url: String.t(),
            state: String.t(),
            verifier: String.t()
          }
  end

  defmodule CompleteInput do
    @moduledoc "Input required to complete an OpenAI Codex OAuth login."

    use JSONCodec, fast_path: :json, strict: true

    defstruct [:authorization_input, :state, :verifier]

    @type t :: %__MODULE__{
            authorization_input: String.t(),
            state: String.t(),
            verifier: String.t()
          }
  end

  @spec start(map(), map()) :: Incant.ActionResult.t()
  def start(_params, _assigns) do
    verifier = CodexLogin.new_verifier()
    state = CodexLogin.new_state()
    challenge = CodexLogin.pkce_challenge(verifier)

    result = %StartResult{
      authorization_url: CodexLogin.authorize_url(challenge, state),
      state: state,
      verifier: verifier
    }

    Incant.ActionResult.job("codex_oauth", label: "OpenAI Codex OAuth", meta: %{oauth: result})
  end

  @spec complete(map(), map()) :: Incant.ActionResult.t()
  def complete(_params, assigns) do
    with {:ok, input} <- cast_complete_input(assigns),
         :ok <- LLMProxy.ReleaseTasks.ensure_http_client_started(),
         {:ok, code} <-
           CodexLogin.parse_authorization_input(input.authorization_input, input.state),
         {:ok, credentials} <- CodexLogin.exchange_code(code, input.verifier),
         {:ok, token} <- store_credentials(credentials) do
      Incant.ActionResult.toast(
        "Connected OpenAI Codex account #{account_label(token.account_id)}."
      )
    else
      {:error, reason} -> Incant.ActionResult.error("Codex OAuth failed: #{inspect(reason)}")
    end
  end

  @doc false
  @spec store_credentials(OAuth.t()) ::
          {:ok, LLMProxy.Schemas.ProviderToken.t()} | {:error, term()}
  def store_credentials(%OAuth{} = credentials) do
    LLMProxy.Storage.add_token("openai-codex", "oauth", credentials.access, %{
      refresh_token: credentials.refresh,
      expires_at: credentials.expires_at,
      account_id: credentials.account_id,
      label: "codex-login"
    })
  end

  defp cast_complete_input(%{"input" => %{} = input}), do: cast_complete_input(input)
  defp cast_complete_input(%{input: %{} = input}), do: cast_complete_input(input)

  defp cast_complete_input(assigns) when is_map(assigns) do
    {:ok, CompleteInput.from_map!(assigns)}
  rescue
    error in [ArgumentError, KeyError, FunctionClauseError, JSONCodec.Error] ->
      {:error, {:invalid_complete_input, error}}
  end

  defp account_label(nil), do: "(unknown account)"
  defp account_label(account_id), do: account_id
end
