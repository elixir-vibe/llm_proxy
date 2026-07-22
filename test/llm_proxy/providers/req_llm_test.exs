defmodule LLMProxy.Providers.ReqLLMTest do
  use ExUnit.Case

  alias Elixir.ReqLLM.StreamEvent
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.{Attempt, Execution, ReqLLM, Result}
  alias LLMProxy.Providers.ReqLLM.Projection
  alias LLMProxy.Storage
  alias LLMProxy.Stream.Event
  alias LLMProxy.TestSupport
  alias LLMProxy.TokenPool.Server, as: TokenPool
  alias Req.Test, as: ReqTest

  defmodule HTTPStub do
  end

  setup do
    TestSupport.checkout_repo()
    :ok = TestSupport.allow_token_pool()
    TestSupport.clear_provider_tokens()
    TokenPool.clear_rate_limits()

    original_providers = Application.get_env(:llm_proxy, :providers)

    Application.put_env(:llm_proxy, :providers, %{
      "configured-test" => %{
        adapter: "openai",
        base_url: "https://configured.example/v1",
        req_http_options: [plug: {ReqTest, HTTPStub}]
      }
    })

    on_exit(fn ->
      if is_nil(original_providers) do
        Application.delete_env(:llm_proxy, :providers)
      else
        Application.put_env(:llm_proxy, :providers, original_providers)
      end
    end)

    :ok
  end

  test "executes a configured provider through ReqLLM and its isolated token pool" do
    test_pid = self()
    telemetry_handler = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_handler,
        [:req_llm, :request, :start],
        fn _event, _measurements, metadata, pid -> send(pid, {:request_metadata, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    ReqTest.stub(HTTPStub, fn conn ->
      send(test_pid, {:request, conn.request_path, conn.body_params, conn.req_headers})

      ReqTest.json(conn, %{
        "id" => "chatcmpl-configured",
        "model" => "upstream-model",
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{
              "role" => "assistant",
              "content" => "OK",
              "reasoning_content" => "brief thought"
            }
          }
        ],
        "usage" => %{
          "prompt_tokens" => 9,
          "completion_tokens" => 4,
          "total_tokens" => 13
        }
      })
    end)

    {:ok, token} = Storage.add_token("isolated-pool", "api-key", "configured-token")

    attempt = %Attempt{
      provider: ReqLLM,
      provider_name: "configured-test",
      model: "upstream-model",
      token_pool: "isolated-pool"
    }

    body = %{
      "model" => "public-alias",
      "messages" => [%{"role" => "user", "content" => "reply OK"}]
    }

    request = %Request{
      protocol: :openai_chat,
      model: "public-alias",
      body: body,
      messages: []
    }

    assert {:ok, %Result{token: ^token, response: response}} =
             Execution.call_attempts([attempt], request, "user-1")

    assert get_in(response, ["choices", Access.at(0), "message"]) == %{
             "role" => "assistant",
             "content" => "OK",
             "reasoning_content" => "brief thought"
           }

    assert response["usage"]["prompt_tokens"] == 9

    assert_receive {:request, "/v1/chat/completions", request_body, headers}
    assert request_body["model"] == "upstream-model"
    assert {"authorization", "Bearer configured-token"} in headers

    assert_receive {:request_metadata, metadata}

    assert metadata.request_options.receive_timeout ==
             LLMProxy.Config.provider_receive_timeout_ms()
  end

  test "normalizes a prior provider tool-call turn before configured execution" do
    test_pid = self()

    ReqTest.stub(HTTPStub, fn conn ->
      send(test_pid, {:mixed_context_request, conn.body_params})

      ReqTest.json(conn, %{
        "id" => "chatcmpl-mixed-context",
        "model" => "upstream-model",
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "continued"}
          }
        ],
        "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 1, "total_tokens" => 13}
      })
    end)

    {:ok, _token} = Storage.add_token("isolated-pool", "api-key", "configured-token")

    attempt = %Attempt{
      provider: ReqLLM,
      provider_name: "configured-test",
      model: "upstream-model",
      token_pool: "isolated-pool"
    }

    body = %{
      "model" => "upstream-model",
      "messages" => [
        %{"role" => "user", "content" => "inspect"},
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "call-1",
              "type" => "function",
              "function" => %{"name" => "inspect_value", "arguments" => ~s({"id":1})}
            }
          ]
        },
        %{"role" => "tool", "tool_call_id" => "call-1", "content" => ~s({"value":42})},
        %{"role" => "user", "content" => "continue"}
      ]
    }

    assert {:ok, %Result{}} = ReqLLM.call(body, "user-1", attempt)
    assert_receive {:mixed_context_request, request}

    assert get_in(request, ["messages", Access.at(1), "tool_calls", Access.at(0), "id"]) ==
             "call-1"

    assert get_in(request, ["messages", Access.at(2), "tool_call_id"]) == "call-1"
  end

  test "token proxy overrides the configured base URL" do
    test_pid = self()

    ReqTest.stub(HTTPStub, fn conn ->
      send(test_pid, {:proxy_request, conn.host, conn.request_path})

      ReqTest.json(conn, %{
        "id" => "chatcmpl-proxy",
        "model" => "upstream-model",
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "OK"}
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      })
    end)

    {:ok, _token} =
      Storage.add_token("isolated-pool", "api-key", "configured-token", %{
        proxy: "https://token-proxy.example/custom"
      })

    attempt = %Attempt{
      provider: ReqLLM,
      provider_name: "configured-test",
      model: "upstream-model",
      token_pool: "isolated-pool"
    }

    body = %{
      "model" => "upstream-model",
      "messages" => [%{"role" => "user", "content" => "hello"}]
    }

    assert {:ok, %Result{}} = ReqLLM.call(body, "user-1", attempt)
    assert_receive {:proxy_request, "token-proxy.example", "/custom/chat/completions"}
  end

  test "normalizes strict tools and maximum reasoning through ReqLLM" do
    test_pid = self()

    ReqTest.stub(HTTPStub, fn conn ->
      send(test_pid, {:tool_request, conn.body_params})

      ReqTest.json(conn, %{
        "id" => "chatcmpl-tool",
        "model" => "upstream-model",
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "tool_calls",
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call-1",
                  "type" => "function",
                  "function" => %{"name" => "echo", "arguments" => ~s({"text":"OK"})}
                }
              ]
            }
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 3, "total_tokens" => 13}
      })
    end)

    {:ok, _token} = Storage.add_token("isolated-pool", "api-key", "configured-token")

    attempt = %Attempt{
      provider: ReqLLM,
      provider_name: "configured-test",
      model: "upstream-model",
      token_pool: "isolated-pool"
    }

    body = %{
      "model" => "upstream-model",
      "messages" => [%{"role" => "user", "content" => "call echo"}],
      "reasoning_effort" => "max",
      "tool_choice" => "required",
      "tools" => [
        %{
          "type" => "function",
          "function" => %{
            "name" => "echo",
            "description" => "Echo text",
            "strict" => true,
            "parameters" => %{
              "type" => "object",
              "properties" => %{"text" => %{"type" => "string"}},
              "required" => ["text"],
              "additionalProperties" => false
            }
          }
        }
      ]
    }

    assert {:ok, %Result{response: response}} = ReqLLM.call(body, "user-1", attempt)
    assert get_in(response, ["choices", Access.at(0), "finish_reason"]) == "tool_calls"

    assert get_in(response, ["choices", Access.at(0), "message", "tool_calls"]) == [
             %{
               "id" => "call-1",
               "type" => "function",
               "function" => %{"name" => "echo", "arguments" => ~s({"text":"OK"})}
             }
           ]

    assert_receive {:tool_request, request}
    assert request["reasoning_effort"] == "max"
    assert request["tool_choice"] == "required"
    assert get_in(request, ["tools", Access.at(0), "function", "strict"]) == true
  end

  test "preserves the selected token on ReqLLM upstream errors" do
    ReqTest.stub(HTTPStub, fn conn ->
      conn
      |> Plug.Conn.put_status(429)
      |> ReqTest.json(%{
        "error" => %{"message" => "slow down", "type" => "rate_limit_error"}
      })
    end)

    {:ok, token} = Storage.add_token("isolated-pool", "api-key", "configured-token")

    attempt = %Attempt{
      provider: ReqLLM,
      provider_name: "configured-test",
      model: "upstream-model",
      token_pool: "isolated-pool"
    }

    body = %{
      "model" => "upstream-model",
      "messages" => [%{"role" => "user", "content" => "hello"}]
    }

    assert {:error, %Result{token: ^token, status: status, error: error}} =
             ReqLLM.call(body, "user-1", attempt)

    assert status == 429
    assert error =~ "slow down"
  end

  test "projects ReqLLM streaming text, reasoning, usage, and finish events" do
    events =
      [
        StreamEvent.new(:start, %{model: "upstream-model"}),
        StreamEvent.new(:reasoning_delta, "think"),
        StreamEvent.new(:text_delta, "OK"),
        StreamEvent.new(:usage, %{input_tokens: 9, output_tokens: 4, total_tokens: 13}),
        StreamEvent.new(:finish, %{finish_reason: :stop})
      ]
      |> Enum.flat_map(&Projection.events(&1, "upstream-model"))

    assert Enum.any?(events, fn %Event{data: data} ->
             get_in(data, ["choices", Access.at(0), "delta", "reasoning_content"]) == "think"
           end)

    assert Enum.any?(events, fn %Event{data: data} ->
             get_in(data, ["choices", Access.at(0), "delta", "content"]) == "OK"
           end)

    assert %Event{usage: %{input_tokens: 9, output_tokens: 4}} =
             Enum.find(events, &match?(%Event{usage: %{}}, &1))

    assert get_in(List.last(events).data, ["choices", Access.at(0), "finish_reason"]) == "stop"
  end
end
