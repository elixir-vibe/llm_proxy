if Code.ensure_loaded?(Incant) do
  defmodule LLMProxy.Admin.Resources.ProviderTokenTest do
    use ExUnit.Case, async: false

    @moduletag :incant

    alias Incant.ActionResult
    alias Incant.Live.FormState
    alias LLMProxy.Admin.Resources.ProviderToken
    alias LLMProxy.Storage

    setup do
      LLMProxy.TestSupport.checkout_repo()
    end

    test "edits only provider-token priority" do
      {:ok, token} =
        Storage.add_token("openai", "api-key", "priority-admin-token", %{priority: 10})

      resource = Incant.metadata(ProviderToken)

      assert Enum.map(Incant.Forms.fields(resource), & &1.name) == [:priority]
      assert Enum.any?(resource.table.actions, &(&1.name == :edit))

      assert {:ok, "Record updated", updated} =
               FormState.save(:edit, resource, token, %{
                 "priority" => "42",
                 "token" => "must-not-replace-token"
               })

      assert updated.priority == 42
      assert updated.token == token.token
    end

    test "enables, disables, and removes provider tokens" do
      {:ok, token} = Storage.add_token("openai", "api-key", "admin-token")
      id = to_string(token.id)

      assert {:ok, %ActionResult.Refresh{}} = ProviderToken.disable(%{id: id}, %{})
      assert [%{enabled: false}] = Storage.list_tokens(%{provider: "openai"})

      assert {:ok, %ActionResult.Refresh{}} = ProviderToken.enable(%{id: id}, %{})
      assert [%{enabled: true}] = Storage.list_tokens(%{provider: "openai"})

      assert {:ok, %ActionResult.Refresh{}} = ProviderToken.remove(%{id: id}, %{})
      assert Storage.list_tokens(%{provider: "openai"}) == []
    end
  end
end
