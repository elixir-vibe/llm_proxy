defmodule LLMProxy.Provider.SafeRPCTest do
  use ExUnit.Case

  alias Ecto.Adapters.SQL.Sandbox
  alias LLMProxy.Providers.{Registry, Result}
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  defmodule Server do
    use SafeRPC.Adapter.Server, service: LLMProxy
  end

  defmodule Provider do
    def name, do: "req-llm-safe-rpc-provider"
    def models, do: ["req-llm-safe-rpc-model"]

    def call(%{"model" => "req-llm-safe-rpc-model", "messages" => _messages}, _user_id) do
      {:ok,
       Result.response(
         %{
           "id" => "req-llm-safe-rpc-1",
           "choices" => [
             %{
               "message" => %{"role" => "assistant", "content" => "hello over SafeRPC"},
               "finish_reason" => "stop"
             }
           ],
           "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 4}
         },
         nil
       )}
    end

    def extract_usage(response) do
      usage = response["usage"] || %{}
      LLMProxy.Usage.new(usage["prompt_tokens"] || 0, usage["completion_tokens"] || 0)
    end

    def to_openai_response(response, model), do: Map.put(response, "model", model)
  end

  setup do
    TestSupport.checkout_repo()
    Registry.register(Provider)
    ReqLLM.Providers.register(LLMProxy.Provider)
    :ok
  end

  test "ReqLLM :llm_proxy provider uses SafeRPC when safe_rpc is supplied" do
    {:ok, _key, raw_key} = Storage.create_key("req-llm-safe-rpc-user")
    socket = socket_path("req-llm")
    {:ok, server} = Server.start_link(socket: socket)
    Sandbox.allow(LLMProxy.Storage.Repo.SQLite, self(), server)

    model = %{
      id: "req-llm-safe-rpc-model",
      provider: :llm_proxy,
      model: "req-llm-safe-rpc-model"
    }

    assert {:ok, response} =
             ReqLLM.Generation.generate_text(model, "hello", safe_rpc: socket, api_key: raw_key)

    assert ReqLLM.Response.text(response) == "hello over SafeRPC"
    assert response.usage.input_tokens == 5

    GenServer.stop(server)
  end

  defp socket_path(name) do
    Path.join(
      System.tmp_dir!(),
      "llm-proxy-req-llm-safe-rpc-#{name}-#{System.unique_integer([:positive])}.sock"
    )
  end
end
