defmodule LLMProxy.Schemas.MessageLog do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "message_log" do
    field(:key_id, :string)
    field(:model, :string)
    field(:route, :string)
    field(:user_message, :string)
    field(:timestamp, :utc_datetime)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:key_id, :model, :route, :user_message, :timestamp])
    |> validate_required([:key_id, :model, :route, :user_message, :timestamp])
  end
end
