defmodule LLMProxy.Providers.OpenAICodex.OAuth.Login do
  @moduledoc """
  Interactive OpenAI Codex OAuth login for standalone LLMProxy releases.

  The browser-facing OAuth protocol returns JSON/string-keyed provider data.
  This module owns that external boundary and converts successful token responses
  into `LLMProxy.Providers.OpenAICodex.OAuth` credentials for storage.
  """

  alias LLMProxy.Providers.OpenAICodex.OAuth

  defmodule TokenResponse do
    @moduledoc """
    OpenAI OAuth token endpoint response.

    This struct is the JSON boundary for `auth.openai.com/oauth/token`.
    """

    use JSONCodec, strict: true, fast_path: :json

    defstruct [:access_token, :refresh_token, :expires_at]

    @type t :: %__MODULE__{
            access_token: String.t(),
            refresh_token: String.t(),
            expires_at: DateTime.t()
          }

    codec(:expires_at, as: "expires_in", cast: :expires_datetime)

    def expires_datetime(expires_in) when is_integer(expires_in) do
      DateTime.utc_now() |> DateTime.add(expires_in, :second) |> DateTime.truncate(:second)
    end
  end

  defmodule AuthClaims do
    @moduledoc "OpenAI auth claim payload embedded in the Codex access-token JWT."

    use JSONCodec, strict: true, fast_path: :json

    defstruct [:chatgpt_account_id]

    @type t :: %__MODULE__{chatgpt_account_id: String.t() | nil}
  end

  defmodule AccessTokenClaims do
    @moduledoc "Codex access-token JWT claims used by LLMProxy."

    use JSONCodec, strict: true, fast_path: :json

    defstruct [:auth]

    @type t :: %__MODULE__{auth: AuthClaims.t() | nil}

    codec(:auth, as: "https://api.openai.com/auth")
  end

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @authorize_url "https://auth.openai.com/oauth/authorize"
  @token_url "https://auth.openai.com/oauth/token"
  @redirect_uri "http://localhost:1455/auth/callback"
  @scope "openid profile email offline_access"
  @type post_fun :: (String.t(), keyword() -> {:ok, Req.Response.t()} | {:error, term()})

  @spec authorize_url(String.t(), String.t(), String.t()) :: String.t()
  def authorize_url(challenge, state, originator \\ "llm_proxy") do
    query =
      URI.encode_query(%{
        response_type: "code",
        client_id: @client_id,
        redirect_uri: @redirect_uri,
        scope: @scope,
        code_challenge: challenge,
        code_challenge_method: "S256",
        state: state,
        id_token_add_organizations: "true",
        codex_cli_simplified_flow: "true",
        originator: originator
      })

    @authorize_url <> "?" <> query
  end

  @spec new_verifier() :: String.t()
  def new_verifier, do: random_urlsafe(64)

  @spec new_state() :: String.t()
  def new_state, do: random_urlsafe(24)

  @spec pkce_challenge(String.t()) :: String.t()
  def pkce_challenge(verifier), do: verifier |> then(&:crypto.hash(:sha256, &1)) |> base64url()

  @spec parse_authorization_input(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def parse_authorization_input(input, state) when is_binary(input) and is_binary(state) do
    input = String.trim(input)

    cond do
      input == "" ->
        {:error, :authorization_code_missing}

      String.contains?(input, "://") ->
        input |> URI.parse() |> authorization_code_from_uri(state)

      String.contains?(input, "code=") ->
        input |> URI.decode_query() |> authorization_code_from_params(state)

      true ->
        {:ok, input}
    end
  end

  @spec exchange_code(String.t(), String.t(), post_fun()) :: {:ok, OAuth.t()} | {:error, term()}
  def exchange_code(code, verifier, post_fun \\ &Req.post/2) do
    body =
      URI.encode_query(%{
        grant_type: "authorization_code",
        client_id: @client_id,
        code: code,
        code_verifier: verifier,
        redirect_uri: @redirect_uri
      })

    post_token(body, post_fun)
  end

  @spec parse_token_response(map() | String.t()) :: {:ok, OAuth.t()} | {:error, term()}
  def parse_token_response(body) when is_binary(body) do
    case TokenResponse.decode(body) do
      {:ok, response} -> token_response_to_oauth(response)
      {:error, reason} -> {:error, {:invalid_token_response, reason}}
    end
  end

  def parse_token_response(body) when is_map(body) do
    case TokenResponse.from_map(body) do
      {:ok, response} -> token_response_to_oauth(response)
      {:error, reason} -> {:error, {:invalid_token_response, reason}}
    end
  end

  defp token_response_to_oauth(%TokenResponse{} = response) do
    OAuth.new(
      response.access_token,
      response.refresh_token,
      response.expires_at,
      account_id(response.access_token)
    )
  end

  @spec account_id(String.t()) :: String.t() | nil
  def account_id(jwt) when is_binary(jwt) do
    with [_header, payload, _sig] <- String.split(jwt, "."),
         {:ok, %AccessTokenClaims{auth: %AuthClaims{} = auth}} <-
           payload |> base64url_decode() |> AccessTokenClaims.decode() do
      auth.chatgpt_account_id
    else
      _ -> nil
    end
  end

  defp post_token(body, post_fun) do
    case post_fun.(@token_url,
           headers: [{"content-type", "application/x-www-form-urlencoded"}],
           body: body
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> parse_token_response(body)
      {:ok, response} -> {:error, {:http_error, response.status, response.body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorization_code_from_uri(%URI{query: query}, state) do
    query
    |> to_string()
    |> URI.decode_query()
    |> authorization_code_from_params(state)
  end

  defp authorization_code_from_params(%{"state" => state, "code" => code}, state)
       when is_binary(code) and code != "" do
    {:ok, code}
  end

  defp authorization_code_from_params(%{"state" => other_state}, _state)
       when is_binary(other_state) do
    {:error, :state_mismatch}
  end

  defp authorization_code_from_params(%{"code" => code}, _state)
       when is_binary(code) and code != "" do
    {:ok, code}
  end

  defp authorization_code_from_params(_params, _state), do: {:error, :authorization_code_missing}

  defp random_urlsafe(bytes), do: bytes |> :crypto.strong_rand_bytes() |> base64url()
  defp base64url(binary), do: Base.url_encode64(binary, padding: false)

  defp base64url_decode(value) do
    padding = String.duplicate("=", rem(4 - rem(byte_size(value), 4), 4))
    Base.url_decode64!(value <> padding, padding: true)
  end
end
