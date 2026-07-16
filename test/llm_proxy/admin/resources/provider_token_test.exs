defmodule LLMProxy.Admin.Resources.ProviderTokenTest do
  use ExUnit.Case, async: false

  alias Incant.ActionResult
  alias LLMProxy.Admin.Resources.ProviderToken
  alias LLMProxy.Storage

  setup do
    LLMProxy.TestSupport.checkout_repo()
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
