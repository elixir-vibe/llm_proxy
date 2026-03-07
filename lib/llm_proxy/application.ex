defmodule LLMProxy.Application do
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    LLMProxy.Providers.Registry.init()
    LLMProxy.Routes.Dynamic.init()
    LLMProxy.Providers.Registry.register(LLMProxy.Providers.OpenRouter)

    children = [
      LLMProxy.Repo,
      LLMProxy.TokenPool.Server,
      {Plug.Cowboy, scheme: :http, plug: LLMProxy.Router, options: [port: port()]}
    ]

    opts = [strategy: :one_for_one, name: LLMProxy.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    seed_tokens_from_env()
    Logger.info("LLM Proxy started on port #{port()}")

    {:ok, pid}
  end

  defp port do
    Application.get_env(:llm_proxy, :port, 4000)
  end

  defp seed_tokens_from_env do
    entries =
      [
        {"openrouter", "api-key", :openrouter_api_keys},
        {"openai", "api-key", :openai_api_keys}
      ]
      |> Enum.map(fn {provider, kind, config_key} ->
        tokens =
          Application.get_env(:llm_proxy, config_key, "")
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        %{provider: provider, kind: kind, tokens: tokens}
      end)
      |> Enum.reject(fn e -> e.tokens == [] end)

    if entries != [] do
      LLMProxy.Storage.seed_tokens_from_env(entries)
    end
  end
end
