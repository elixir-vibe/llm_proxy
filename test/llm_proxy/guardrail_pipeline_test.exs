defmodule LLMProxy.GuardrailPipelineTest do
  use ExUnit.Case

  alias LLMProxy.HTTP.Routes.Chat
  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Storage
  alias LLMProxy.Stream.Event
  alias LLMProxy.TestSupport

  defmodule Provider do
    def name, do: "guardrail-provider-test"
    def models, do: ["guardrail-model"]

    def call(%{"model" => "guardrail-model"}, _user_id) do
      {:ok,
       Result.response(
         %{
           "id" => "guardrail-response",
           "choices" => [
             %{
               "message" => %{"role" => "assistant", "content" => "original"},
               "finish_reason" => "stop"
             }
           ],
           "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
         },
         nil
       )}
    end

    def stream(_body, _user_id) do
      {:ok,
       Result.stream(
         [
           Event.new(%{
             "id" => "guardrail-stream",
             "choices" => [%{"delta" => %{"content" => "drop"}}]
           }),
           Event.new(%{
             "id" => "guardrail-stream",
             "choices" => [%{"delta" => %{"content" => "keep"}}]
           })
         ],
         nil
       )}
    end

    def extract_usage(response) do
      usage = response["usage"] || %{}
      LLMProxy.Usage.new(usage["prompt_tokens"] || 0, usage["completion_tokens"] || 0)
    end

    def to_openai_response(response, model), do: Map.put(response, "model", model)
  end

  defmodule DenyGuardrail do
    @behaviour LLMProxy.Guardrail

    @impl LLMProxy.Guardrail
    def before_request(_request, _context), do: {:error, :blocked}
  end

  defmodule ResponseGuardrail do
    @behaviour LLMProxy.Guardrail

    @impl LLMProxy.Guardrail
    def after_response(response, _context) do
      {:ok, LLMProxy.Response.put_text(response, "redacted")}
    end
  end

  defmodule StreamGuardrail do
    @behaviour LLMProxy.Guardrail

    @impl LLMProxy.Guardrail
    def on_stream_event(
          %Event{data: %{"choices" => [%{"delta" => %{"content" => "drop"}}]}} = _event,
          _context
        ) do
      {:ok, nil}
    end

    def on_stream_event(event, _context), do: {:ok, event}
  end

  defmodule StrictStreamGuardrail do
    @behaviour LLMProxy.Guardrail

    @impl LLMProxy.Guardrail
    def on_stream_event(%Event{} = event, _context), do: {:ok, event}
  end

  setup do
    TestSupport.checkout_repo()
    LLMProxy.Drain.cancel()
    Registry.register(Provider)

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :guardrails)
      LLMProxy.Drain.cancel()
    end)

    :ok
  end

  test "before_request can reject provider calls" do
    Application.put_env(:llm_proxy, :guardrails, [DenyGuardrail])
    {:ok, key, _raw_key} = Storage.create_key("guardrail-deny-user")

    assert {:error, {:guardrail, :blocked}} =
             LLMProxy.chat("hello", model: "guardrail-model", api_key: key)
  end

  test "guardrail config rejects non-module entries" do
    Application.put_env(:llm_proxy, :guardrails, ["not-a-module"])
    {:ok, key, _raw_key} = Storage.create_key("guardrail-invalid-user")

    assert_raise ArgumentError, ~r/guardrails must be module atoms/, fn ->
      LLMProxy.chat("hello", model: "guardrail-model", api_key: key)
    end
  end

  test "after_response can modify provider responses" do
    Application.put_env(:llm_proxy, :guardrails, [ResponseGuardrail])
    {:ok, key, _raw_key} = Storage.create_key("guardrail-response-user")

    assert {:ok, response} = LLMProxy.chat("hello", model: "guardrail-model", api_key: key)

    assert get_in(LLMProxy.Response.to_openai(response), [
             "choices",
             Access.at(0),
             "message",
             "content"
           ]) == "redacted"
  end

  test "filtered stream chunks stop before later guardrails" do
    Application.put_env(:llm_proxy, :guardrails, [StreamGuardrail, StrictStreamGuardrail])

    assert {:ok, nil} =
             LLMProxy.GuardrailPipeline.on_stream_event(
               %Event{data: %{"choices" => [%{"delta" => %{"content" => "drop"}}]}},
               %{}
             )
  end

  test "on_stream_event can filter stream chunks" do
    Application.put_env(:llm_proxy, :guardrails, [StreamGuardrail])
    {:ok, _key, raw_key} = Storage.create_key("guardrail-stream-user")

    conn =
      TestSupport.json_conn(:post, "/completions", %{
        "model" => "guardrail-model",
        "stream" => true,
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })
      |> TestSupport.put_bearer(raw_key)
      |> Chat.call(Chat.init([]))

    assert conn.status == 200
    refute conn.resp_body =~ "drop"
    assert conn.resp_body =~ "keep"
  end
end
