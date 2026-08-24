if Code.ensure_loaded?(Incant) do
  defmodule LLMProxy.AdminTransportTest do
    use ExUnit.Case

    alias LLMProxy.{Admin, Storage, TestSupport}

    setup do
      TestSupport.checkout_repo()
      :ok
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
