defmodule LlmProxy.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LlmProxy.Repo,
      LlmProxy.TokenPool.Server,
      {Plug.Cowboy, scheme: :http, plug: LlmProxy.Router, options: [port: port()]}
    ]

    opts = [strategy: :one_for_one, name: LlmProxy.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp port do
    Application.get_env(:llm_proxy, :port, 4000)
  end
end
