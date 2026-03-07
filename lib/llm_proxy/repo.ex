defmodule LlmProxy.Repo do
  use Ecto.Repo,
    otp_app: :llm_proxy,
    adapter: Ecto.Adapters.SQLite3
end
