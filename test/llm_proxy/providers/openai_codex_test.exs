defmodule LLMProxy.Providers.OpenAICodexTest do
  use ExUnit.Case

  alias LLMProxy.{Catalog, ModelDB}
  alias LLMProxy.Catalog.{Deployment, Model}
  alias LLMProxy.Providers.Attempt
  alias LLMProxy.Providers.{OpenAICodex, Registry, Result}
  alias LLMProxy.Providers.OpenAICodex.Events
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
    assert opts[:connect_timeout] == LLMProxy.Config.provider_connect_timeout_ms()
    assert opts[:receive_timeout] == :infinity
  end

  test "Chat input preserves tools for ReqLLM generation" do
    tool = %{
      "type" => "function",
      "function" => %{
        "name" => "add",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"a" => %{"type" => "number"}},
          "required" => ["a"]
        }
      }
    }

    assert {:ok, request} =
             OpenAICodex.request_from_chat_body(%{
               "model" => "gpt-5.3-codex-spark",
               "messages" => [%{"role" => "user", "content" => "use add"}],
               "tools" => [tool],
               "tool_choice" => "auto"
             })

    assert request.model == "gpt-5.3-codex-spark"
    assert request.tools == [tool]
    assert request.tool_choice == "auto"
    assert [%{role: :user}] = request.messages
  end

  test "Responses named tool choice uses ReqLLM canonical form" do
    assert {:ok, request} =
             OpenAICodex.request_from_responses_body(%{
               "model" => "gpt-5.6-sol",
               "input" => [%{"role" => "user", "content" => "use lookup"}],
               "tool_choice" => %{"type" => "function", "name" => "lookup"}
             })

    assert request.tool_choice == %{type: "tool", name: "lookup"}
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

  test "lazy stream errors preserve a safe upstream reason" do
    result = OpenAICodex.stream_error(RuntimeError.exception("WebSocket closed 1000"), nil)

    assert result.status == 502
    assert result.error == "WebSocket closed 1000"

    assert Result.client_error(result) == %{
             "message" => "WebSocket closed 1000",
             "type" => "upstream_error",
             "code" => "upstream_error",
             "status" => 502
           }
  end

  test "extract_usage handles Responses usage" do
    usage = OpenAICodex.extract_usage(%{"usage" => %{"input_tokens" => 4, "output_tokens" => 5}})

    assert usage.input_tokens == 4
    assert usage.output_tokens == 5
  end

  test "stream chunks are converted to Responses events" do
    text_event = Events.responses_event(StreamChunk.text("hi"))
    assert text_event.data["type"] == "response.output_text.delta"
    assert text_event.data["delta"] == "hi"

    terminal_event =
      Events.responses_event(
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
    event = Events.openai_chat_event(StreamChunk.text("hello"), "gpt-5.3-codex-spark")

    assert [%{"delta" => %{"content" => "hello"}}] = event.data["choices"]
    assert event.data["model"] == "gpt-5.3-codex-spark"
  end

  test "OpenAI chat stream conversion normalizes tool indexes and terminal finish" do
    chunks = [
      StreamChunk.tool_call("add", %{}, %{id: "call_1", index: 1}),
      StreamChunk.meta(%{tool_call_args: %{index: 1, fragment: ~s({"a":2,"b":3})}}),
      StreamChunk.meta(%{terminal?: true, finish_reason: :stop, usage: %{input_tokens: 1}})
    ]

    [tool_start, args, terminal] =
      chunks
      |> Events.openai_chat_events("gpt-5.3-codex-spark")
      |> Enum.to_list()

    assert [%{"delta" => %{"tool_calls" => [start]}}] = tool_start.data["choices"]
    assert start["index"] == 0
    assert start["id"] == "call_1"
    assert start["function"]["name"] == "add"
    assert start["function"]["arguments"] == ""

    assert [%{"delta" => %{"tool_calls" => [arg_delta]}}] = args.data["choices"]
    assert arg_delta["index"] == 0
    assert arg_delta["function"]["arguments"] == ~s({"a":2,"b":3})

    assert [%{"finish_reason" => "tool_calls"}] = terminal.data["choices"]
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
