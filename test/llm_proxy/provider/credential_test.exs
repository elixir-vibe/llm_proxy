defmodule LLMProxy.Provider.CredentialTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Provider.Credential

  test "Inspect redacts request-scoped access and refresh credentials" do
    credential = %Credential{
      id: 1,
      provider: "openai-codex",
      kind: "oauth",
      token: "access-seeded-secret",
      refresh_token: "refresh-seeded-secret"
    }

    inspected = inspect(credential)

    refute inspected =~ "access-seeded-secret"
    refute inspected =~ "refresh-seeded-secret"
    assert inspected =~ "openai-codex"
  end
end
