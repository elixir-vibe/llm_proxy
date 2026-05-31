defmodule LLMProxy.Schemas.UsageLog do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "usage_log" do
    field(:key_id, :string)
    field(:model, :string)
    field(:input_tokens, :integer)
    field(:output_tokens, :integer)
    field(:cache_read_tokens, :integer, default: 0)
    field(:cache_write_tokens, :integer, default: 0)
    field(:cost_usd, :float)
    field(:duration_ms, :integer)
    field(:ttft_ms, :integer)
    field(:provider, :string)
    field(:tags, LLMProxy.Storage.JSON)
    field(:metadata, LLMProxy.Storage.JSON)
    field(:timestamp, :utc_datetime)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :key_id,
      :model,
      :input_tokens,
      :output_tokens,
      :cache_read_tokens,
      :cache_write_tokens,
      :cost_usd,
      :duration_ms,
      :ttft_ms,
      :provider,
      :tags,
      :metadata,
      :timestamp
    ])
    |> validate_required([:key_id, :model, :input_tokens, :output_tokens, :timestamp])
  end
end
