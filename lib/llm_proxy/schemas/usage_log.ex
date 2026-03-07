defmodule LlmProxy.Schemas.UsageLog do
  use Ecto.Schema
  import Ecto.Changeset

  schema "usage_log" do
    field :key_id, :string
    field :model, :string
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cache_read_tokens, :integer, default: 0
    field :cache_write_tokens, :integer, default: 0
    field :timestamp, :utc_datetime
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:key_id, :model, :input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens, :timestamp])
    |> validate_required([:key_id, :model, :input_tokens, :output_tokens, :timestamp])
  end
end
