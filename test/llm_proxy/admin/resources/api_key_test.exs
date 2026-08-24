if Code.ensure_loaded?(Incant) do
  defmodule LLMProxy.Admin.Resources.ApiKeyTest do
    use ExUnit.Case, async: false

    @moduletag :incant

    alias Incant.ActionResult
    alias LLMProxy.Admin.Resources.ApiKey
    alias LLMProxy.Storage

    setup do
      LLMProxy.TestSupport.checkout_repo()
    end

    test "creates, disables, enables, and deletes API keys" do
      assert {:ok, %ActionResult.Job{id: "api_key:" <> _id, meta: meta}} =
               ApiKey.create(%{}, %{
                 "name" => "operator-test",
                 "trace_requests" => true,
                 "capture_content" => true
               })

      assert %{id: id, name: "operator-test", token: "sk-proxy-" <> _} = meta
      assert key = Storage.find_key(meta.token)
      assert key.id == id
      assert key.trace_requests == true
      assert key.capture_content == true

      assert {:ok, %ActionResult.Refresh{}} = ApiKey.disable(%{id: id}, %{})
      assert Storage.find_key(meta.token) == nil

      assert {:ok, %ActionResult.Refresh{}} = ApiKey.enable(%{id: id}, %{})
      assert Storage.find_key(meta.token).id == id

      assert {:ok, %ActionResult.Refresh{}} = ApiKey.delete(%{id: id}, %{})
      assert Storage.list_keys() == []
    end
  end
end
