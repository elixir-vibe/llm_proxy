defmodule LLMProxy.Application do
  @moduledoc """
  OTP application callback that starts LLMProxy storage, routing state, token pools, RPC, and HTTP serving.
  """

  use Application

  require Logger

  alias LLMProxy.Providers.Registry
  alias LLMProxy.Storage.Repo

  @impl true
  def start(_type, _args) do
    setup_opentelemetry()

    Registry.init()
    LLMProxy.Catalog.init()
    LLMProxy.Pricing.init()
    Registry.register(LLMProxy.Providers.OpenRouter)
    Registry.register(LLMProxy.Providers.Anthropic)
    Registry.register(LLMProxy.Providers.OpenAI)
    Registry.register(LLMProxy.Providers.OpenAICodex)
    ReqLLM.Providers.register(LLMProxy.Provider)

    children =
      storage_children() ++
        [
          LLMProxy.Drain,
          LLMProxy.Providers.CircuitBreaker,
          LLMProxy.Providers.Routing.RoundRobin,
          LLMProxy.TokenPool.Server
        ] ++ rpc_children() ++ http_children()

    opts = [strategy: :one_for_one, name: LLMProxy.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    seed_tokens_from_env()
    Logger.info("LLM Proxy started")

    {:ok, pid}
  end

  defp storage_children do
    if Repo.bundled?() do
      [
        %{
          id: LLMProxy.Storage.Supervisor,
          start:
            {Supervisor, :start_link,
             [
               quackdb_server_children() ++ [Repo.configured()],
               [strategy: :rest_for_one, name: LLMProxy.Storage.Supervisor]
             ]}
        }
      ]
    else
      []
    end
  end

  defp quackdb_server_children do
    if Repo.adapter() == Ecto.Adapters.QuackDB do
      [{LLMProxy.Storage.QuackDBServer, LLMProxy.Config.quackdb_server_options()}]
    else
      []
    end
  end

  defp rpc_children do
    case LLMProxy.Config.rpc_socket() do
      socket when is_binary(socket) and socket != "" ->
        [
          {LLMProxy.RPC.AdminServer,
           socket: socket, socket_mode: 0o660, name: LLMProxy.RPC.AdminServer}
        ]

      _other ->
        []
    end
  end

  defp http_children do
    if LLMProxy.Config.http_enabled?() and Code.ensure_loaded?(Plug.Cowboy) do
      [
        {Plug.Cowboy,
         scheme: :http,
         plug: LLMProxy.HTTP.Router,
         options: [
           ip: {127, 0, 0, 1},
           port: LLMProxy.Config.http_port(),
           protocol_options: [
             idle_timeout: LLMProxy.Config.provider_receive_timeout_ms(),
             reset_idle_timeout_on_send: true
           ]
         ]}
      ]
    else
      []
    end
  end

  defp setup_opentelemetry do
    :opentelemetry_cowboy.setup()
    OpentelemetryEcto.setup([:llm_proxy, :repo])
  end

  defp seed_tokens_from_env do
    entries =
      [
        {"openrouter", "api-key", :api_keys},
        {"openai", "api-key", :api_keys},
        {"anthropic", "api-key", :api_keys},
        {"openai-codex", "oauth", :oauth_tokens}
      ]
      |> Enum.map(fn {provider, kind, config_key} ->
        tokens =
          provider
          |> LLMProxy.Config.provider_value(config_key, "")
          |> token_entries(provider)

        token_seed(provider, kind, tokens)
      end)
      |> Kernel.++(configured_provider_key_entries())
      |> Enum.reject(fn e -> e.tokens == [] end)

    if entries != [] do
      LLMProxy.Storage.seed_tokens_from_env(entries)
    end
  end

  defp configured_provider_key_entries do
    Enum.map(LLMProxy.Config.provider_key_seeds(), fn {pool, tokens} ->
      token_seed(to_string(pool), "api-key", token_entries(tokens, to_string(pool)))
    end)
  end

  defp token_seed(provider, kind, tokens) do
    %{provider: provider, kind: kind, tokens: tokens}
  end

  defp token_entries(value, "openai-codex") when is_list(value),
    do: Enum.map(value, &codex_token_entry/1)

  defp token_entries(value, _provider) when is_list(value), do: Enum.map(value, &to_string/1)

  defp token_entries(value, "openai-codex") when is_binary(value) do
    value
    |> split_tokens()
    |> Enum.map(&codex_token_entry/1)
  end

  defp token_entries(value, _provider) when is_binary(value), do: split_tokens(value)
  defp token_entries(_value, _provider), do: []

  defp split_tokens(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp codex_token_entry(%{token: token} = attrs) when is_binary(token) do
    attrs
    |> Map.take([:token, :refresh_token, :expires_at, :account_id])
    |> normalize_expires_at()
  end

  defp codex_token_entry(token) when is_binary(token) do
    case String.split(token, "|", parts: 4) do
      [access, refresh, expires, account_id] ->
        %{
          token: access,
          refresh_token: blank_to_nil(refresh),
          expires_at: parse_expires_at(expires),
          account_id: blank_to_nil(account_id)
        }

      [access, refresh, expires] ->
        %{
          token: access,
          refresh_token: blank_to_nil(refresh),
          expires_at: parse_expires_at(expires)
        }

      [access, refresh] ->
        %{token: access, refresh_token: blank_to_nil(refresh)}

      [access] ->
        %{token: access}
    end
  end

  defp normalize_expires_at(%{expires_at: expires_at} = attrs),
    do: %{attrs | expires_at: parse_expires_at(expires_at)}

  defp normalize_expires_at(attrs), do: attrs

  defp parse_expires_at(nil), do: nil
  defp parse_expires_at(%DateTime{} = expires_at), do: DateTime.truncate(expires_at, :second)

  defp parse_expires_at(expires_at) when is_integer(expires_at) do
    expires_at |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second)
  end

  defp parse_expires_at(expires_at) when is_binary(expires_at) do
    cond do
      expires_at == "" ->
        nil

      match?({_integer, ""}, Integer.parse(expires_at)) ->
        expires_at |> String.to_integer() |> parse_expires_at()

      true ->
        case DateTime.from_iso8601(expires_at) do
          {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
          {:error, _reason} -> nil
        end
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
