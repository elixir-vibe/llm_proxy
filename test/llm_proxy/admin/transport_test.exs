if Code.ensure_loaded?(Incant) do
  defmodule LLMProxy.Admin.TransportTest do
    use ExUnit.Case

    alias LLMProxy.{Admin, Storage, TestSupport}

    setup do
      TestSupport.checkout_repo()
      :ok
    end

    test "redacts sensitive provider proxy values before external index and read results" do
      proxy = "http://proxy-user:proxy-password@127.0.0.1:8080"

      assert {:ok, token} =
               Storage.add_token("openai", "api-key", "transport-provider-token", %{
                 proxy: proxy
               })

      assert {:ok, page} =
               Admin.index(
                 %Incant.Service.Index{surface_id: "provider_token", params: %{}, context: %{}},
                 %{},
                 nil
               )

      refute inspect(page) =~ proxy
      assert cell_value(hd(page["rows"]), "proxy") == "[redacted]"
      assert cell_value(hd(page["rows"]), "provider") == "openai"

      assert {:ok, row} =
               Admin.read(
                 %Incant.Service.Read{
                   surface_id: "provider_token",
                   id: token.id,
                   context: %{}
                 },
                 %{},
                 nil
               )

      refute inspect(row) =~ proxy
      assert cell_value(row, "proxy") == "[redacted]"
      assert cell_value(row, "provider") == "openai"
    end

    test "redacts sensitive message content before external index and read results" do
      secret = "seeded-admin-transport-message-83d1"

      assert {:ok, message} =
               Storage.log_message(%{
                 key_id: "transport-key",
                 model: "transport-model",
                 route: "chat",
                 user_message: secret
               })

      assert {:ok, page} =
               Admin.index(
                 %Incant.Service.Index{surface_id: "message", params: %{}, context: %{}},
                 %{},
                 nil
               )

      refute inspect(page) =~ secret
      assert cell_value(hd(page["rows"]), "user_message") == "[redacted]"
      assert cell_value(hd(page["rows"]), "model") == "transport-model"

      assert {:ok, row} =
               Admin.read(
                 %Incant.Service.Read{surface_id: "message", id: message.id, context: %{}},
                 %{},
                 nil
               )

      refute inspect(row) =~ secret
      assert cell_value(row, "user_message") == "[redacted]"
      assert cell_value(row, "model") == "transport-model"
    end

    defp cell_value(row, column) do
      row["cells"]
      |> Enum.find(&(&1["column"] == column))
      |> Map.fetch!("value")
    end
  end
end
