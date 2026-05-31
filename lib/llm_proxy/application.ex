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
    ReqLLM.Providers.register(LLMProxy.ReqLLM.RemoteProvider)

    Dynamic.register("/v1/messages", LLMProxy.HTTP.Routes.Messages)
    Dynamic.register("/messages", LLMProxy.HTTP.Routes.Messages)
    Dynamic.register("/v1/responses", LLMProxy.HTTP.Routes.Responses)
    Dynamic.register("/responses", LLMProxy.HTTP.Routes.Responses)

    children = [
      LLMProxy.Repo,
      LLMProxy.Providers.CircuitBreaker,
      LLMProxy.Providers.Routing.RoundRobin,
      LLMProxy.TokenPool.Server,
      {Phoenix.PubSub, name: LLMProxy.PubSub},
      LLMProxy.Web.Endpoint
    ]

    opts = [strategy: :one_for_one, name: LLMProxy.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    seed_tokens_from_env()
    Logger.info("LLM Proxy started")

    {:ok, pid}
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
