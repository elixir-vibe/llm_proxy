defmodule LLMProxy.Providers.OpenAICodexTest do
  use ExUnit.Case

  alias LLMProxy.{Catalog, ModelDB}
  alias LLMProxy.Catalog.{Deployment, Model}
  alias LLMProxy.Providers.{OpenAICodex, Registry}
  alias LLMProxy.Providers.Routing.Attempt
  alias ReqLLM.StreamChunk

  test "identity and model discovery stays delegated" do
    assert OpenAICodex.name() == "openai-codex"
    assert OpenAICodex.native_protocol() == :openai
    assert OpenAICodex.models() == ModelDB.provider_model_ids(:openai_codex)

    assert {:ok, %{provider: :openai_codex, provider_model_id: "gpt-5.3-codex-spark"}} =
             ReqLLM.model("openai_codex:gpt-5.3-codex-spark")
  end

  test "Codex routes through existing catalog deployments" do
    Catalog.load([])

    Catalog.put_model(
      Model.new!(
        name: "codex",
        deployments: [
          Deployment.new!(provider: OpenAICodex, upstream_model: "gpt-5.3-codex-spark")
        ]
      )
    )

    assert {:ok, [%Attempt{provider: OpenAICodex, model: "gpt-5.3-codex-spark"}]} =
             Registry.resolve_attempts("codex")

    on_exit(fn -> Catalog.load([]) end)
  end

  test "ReqLLM options use OAuth token and WebSocket streaming" do
    token = %{token: account_token("acct_123")}

    opts = OpenAICodex.req_llm_opts(token, true)
    provider_options = Keyword.fetch!(opts, :provider_options)

    assert provider_options[:auth_mode] == :oauth
    assert provider_options[:access_token] == token.token
    assert provider_options[:chatgpt_account_id] == "acct_123"
    assert provider_options[:codex_originator] == "pi"
    assert provider_options[:openai_stream_transport] == :websocket
  end

  test "Responses input is converted into ReqLLM context messages" do
    {:ok, context} =
      OpenAICodex.context_from_responses_body(%{
        "input" => [
          %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "hello"}]},
          %{"type" => "function_call_output", "call_id" => "call_1", "output" => "42"}
        ]
      })

    assert length(context.messages) == 2
    assert Enum.at(context.messages, 0).role == :user
    assert Enum.at(context.messages, 0).content |> hd() |> Map.fetch!(:text) == "hello"
    assert Enum.at(context.messages, 1).role == :tool
    assert Enum.at(context.messages, 1).tool_call_id == "call_1"
  end

  test "extract_usage handles Responses usage" do
    usage = OpenAICodex.extract_usage(%{"usage" => %{"input_tokens" => 4, "output_tokens" => 5}})

    assert usage.input_tokens == 4
    assert usage.output_tokens == 5
  end

  test "stream chunks are converted to Responses events" do
    text_event = OpenAICodex.to_responses_event(StreamChunk.text("hi"))
    assert text_event.data["type"] == "response.output_text.delta"
    assert text_event.data["delta"] == "hi"

    terminal_event =
      OpenAICodex.to_responses_event(
        StreamChunk.meta(%{
          terminal?: true,
          finish_reason: :stop,
          usage: %{input_tokens: 2, output_tokens: 3}
        })
      )

    assert terminal_event.data["type"] == "response.completed"
    assert terminal_event.usage.input_tokens == 2
    assert terminal_event.usage.output_tokens == 3
  end

  test "stream chunks are converted to OpenAI chat events" do
    event = OpenAICodex.to_openai_chat_event(StreamChunk.text("hello"), "gpt-5.3-codex-spark")

    assert [%{"delta" => %{"content" => "hello"}}] = event.data["choices"]
    assert event.data["model"] == "gpt-5.3-codex-spark"
  end

  defp account_token(account_id) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "none"}), padding: false)

    payload =
      %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    header <> "." <> payload <> ".signature"
  end
end
