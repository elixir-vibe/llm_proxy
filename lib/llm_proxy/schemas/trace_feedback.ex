defmodule LLMProxy.Schemas.TraceFeedback do
  @moduledoc """
  Ecto schema for user feedback associated with traces or request IDs.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "trace_feedback" do
    field(:trace_id, :integer)
    field(:request_id, :string)
    field(:key_id, :string)
    field(:rating, :string)
    field(:comment, :string)
    field(:metadata, LLMProxy.Storage.JSON)
    field(:timestamp, :utc_datetime)
  end

  def changeset(feedback, attrs) do
    feedback
    |> cast(attrs, [:trace_id, :request_id, :key_id, :rating, :comment, :metadata, :timestamp])
    |> validate_required([:request_id, :key_id, :rating, :timestamp])
    |> validate_inclusion(:rating, ["positive", "negative", "neutral"])
  end
end
