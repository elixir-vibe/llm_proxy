if Code.ensure_loaded?(Ecto.Adapters.QuackDB) do
  defmodule LLMProxy.QuackRepo do
    @moduledoc false
    use Ecto.Repo,
      otp_app: :llm_proxy,
      adapter: Ecto.Adapters.QuackDB
  end
end
