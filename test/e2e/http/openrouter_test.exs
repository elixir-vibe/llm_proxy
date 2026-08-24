defmodule LLMProxy.E2E.HTTP.OpenRouterTest do
  use ExUnit.Case

  alias Ecto.Adapters.SQL.Sandbox
  alias LLMProxy.Storage
  alias LLMProxy.Storage.Repo.SQLite
  alias LLMProxy.TokenPool.Server, as: TokenPool

  @moduletag :e2e
  @moduletag timeout: 30_000

  @model "openai/gpt-4o-mini"

  @api_key :llm_proxy
           |> Application.compile_env(:providers, %{})
           |> get_in(["openrouter", :api_keys])
           |> to_string()
           |> String.split(",", trim: true)
           |> List.first()

  if is_nil(@api_key) do
    @moduletag :skip
  end

  setup do
    :ok = Sandbox.checkout(SQLite)
    Sandbox.mode(SQLite, {:shared, self()})

    {:ok, _token} = Storage.add_token("openrouter", "api-key", @api_key)
    TokenPool.clear_rate_limits()

    :ok
  end

  test "serves a chat completion over HTTP" do
    assert {:ok, response} =
             Req.post(url("/v1/chat/completions"),
               headers: auth_headers(),
               json: %{
                 "model" => @model,
                 "messages" => [%{"role" => "user", "content" => "Say hi"}],
                 "max_tokens" => 20
               },
               receive_timeout: 30_000
             )

    assert response.status == 200
    assert [choice | _] = response.body["choices"]
    assert is_binary(choice["message"]["content"])
  end

  defp url(path), do: "http://127.0.0.1:#{LLMProxy.Config.http_port()}#{path}"

  defp auth_headers do
    [{"authorization", "Bearer #{Application.fetch_env!(:llm_proxy, :master_key)}"}]
  end
end
