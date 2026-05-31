if Code.ensure_loaded?(Ecto.Adapters.SQLite3) do
  defmodule LLMProxy.Repo do
    @moduledoc false
    use Ecto.Repo,
      otp_app: :llm_proxy,
      adapter: Ecto.Adapters.SQLite3
  end
end
