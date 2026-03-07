defmodule LLMProxy.Application do
  use Application

  @impl true
  def start(_type, _args) do
    LLMProxy.Providers.Registry.init()
    LLMProxy.Providers.Registry.register(LLMProxy.Providers.OpenRouter)

    children = [
      LLMProxy.Repo,
      LLMProxy.TokenPool.Server,
      {Plug.Cowboy, scheme: :http, plug: LLMProxy.Router, options: [port: port()]}
    ]

    opts = [strategy: :one_for_one, name: LLMProxy.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp port do
    Application.get_env(:llm_proxy, :port, 4000)
  end
end
