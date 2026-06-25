defmodule LLMProxy.Application do
  @moduledoc false

  use Application

  require Logger

  alias LLMProxy.HTTP.Routes.Dynamic
  alias LLMProxy.Providers.Registry

  @impl true
  def start(_type, _args) do
    setup_opentelemetry()

    Registry.init()
    Dynamic.init()
    LLMProxy.Catalog.init()
    LLMProxy.Pricing.init()
    Registry.register(LLMProxy.Providers.OpenRouter)
    Registry.register(LLMProxy.Providers.Anthropic)
    Registry.register(LLMProxy.Providers.OpenAI)
    ReqLLM.Providers.register(LLMProxy.Provider)

    Dynamic.register("/v1/messages", LLMProxy.HTTP.Routes.Messages)
    Dynamic.register("/messages", LLMProxy.HTTP.Routes.Messages)
    Dynamic.register("/v1/responses", LLMProxy.HTTP.Routes.Responses)
    Dynamic.register("/responses", LLMProxy.HTTP.Routes.Responses)

    children =
      storage_children() ++
        [
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
    if LLMProxy.Storage.Repo.bundled?() do
      quackdb_server_children() ++ [LLMProxy.Storage.Repo.configured()]
    else
      []
    end
  end

  defp quackdb_server_children do
    if LLMProxy.Storage.Repo.adapter() == Ecto.Adapters.QuackDB do
      [{QuackDB.Server, LLMProxy.Config.quackdb_server_options()}]
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
         options: [ip: {127, 0, 0, 1}, port: LLMProxy.Config.http_port()]}
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
      ["openrouter", "openai", "anthropic"]
      |> Enum.map(fn provider ->
        tokens =
          provider
          |> LLMProxy.Config.provider_value(:api_keys, "")
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        %{provider: provider, kind: "api-key", tokens: tokens}
      end)
      |> Enum.reject(fn e -> e.tokens == [] end)

    if entries != [] do
      LLMProxy.Storage.seed_tokens_from_env(entries)
    end
  end
end
