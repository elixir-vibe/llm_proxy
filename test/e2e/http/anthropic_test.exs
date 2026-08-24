defmodule LLMProxy.E2E.HTTP.AnthropicTest do
  use ExUnit.Case

  alias Ecto.Adapters.SQL.Sandbox
  alias LLMProxy.Storage
  alias LLMProxy.Storage.Repo.SQLite
  alias LLMProxy.TokenPool.Server, as: TokenPool

  @moduletag :e2e
  @moduletag timeout: 30_000

  @model "claude-3-5-haiku-20241022"

  @api_key :llm_proxy
           |> Application.compile_env(:providers, %{})
           |> get_in(["anthropic", :api_keys])
           |> to_string()
           |> String.split(",", trim: true)
           |> List.first()

  if is_nil(@api_key) do
    @moduletag :skip
  end

  setup do
    :ok = Sandbox.checkout(SQLite)
    Sandbox.mode(SQLite, {:shared, self()})

    {:ok, _token} = Storage.add_token("anthropic", "api-key", @api_key)
    TokenPool.clear_rate_limits()

    :ok
  end

  test "serves an OpenAI-compatible chat response over HTTP" do
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
    assert response.body["object"] == "chat.completion"
    assert [choice | _] = response.body["choices"]
    assert choice["message"]["role"] == "assistant"
    assert is_binary(choice["message"]["content"])
    assert response.body["usage"]["prompt_tokens"] > 0
  end

  test "serves a native Anthropic response over HTTP" do
    assert {:ok, response} =
             Req.post(url("/v1/messages"),
               headers: auth_headers(),
               json: %{
                 "model" => @model,
                 "messages" => [%{"role" => "user", "content" => "Say hi"}],
                 "max_tokens" => 20
               },
               receive_timeout: 30_000
             )

    assert response.status == 200
    assert response.body["type"] == "message"
    assert response.body["role"] == "assistant"
    assert [block | _] = response.body["content"]
    assert block["type"] == "text"
    assert is_binary(block["text"])
  end

  defp url(path), do: "http://127.0.0.1:#{LLMProxy.Config.http_port()}#{path}"

  defp auth_headers do
    [{"authorization", "Bearer #{Application.fetch_env!(:llm_proxy, :master_key)}"}]
  end
end
