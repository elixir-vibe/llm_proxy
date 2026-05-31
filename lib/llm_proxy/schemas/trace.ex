defmodule LLMProxy.Schemas.Trace do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "traces" do
    field(:key_id, :string)
    field(:model, :string)
    field(:provider, :string)
    field(:request_body, :string)
    field(:response_body, :string)
    field(:input_tokens, :integer, default: 0)
    field(:output_tokens, :integer, default: 0)
    field(:cost_usd, :float)
    field(:duration_ms, :integer)
    field(:ttft_ms, :integer)
    field(:tags, LLMProxy.Storage.JSON)
    field(:metadata, LLMProxy.Storage.JSON)
    field(:session_id, :string)
    field(:timestamp, :utc_datetime)
  end

  def changeset(trace, attrs) do
    trace
    |> cast(attrs, [
      :key_id,
      :model,
      :provider,
      :request_body,
      :response_body,
      :input_tokens,
      :output_tokens,
      :cost_usd,
      :duration_ms,
      :ttft_ms,
      :tags,
      :metadata,
      :session_id,
      :timestamp
    ])
    |> validate_required([:key_id, :model, :timestamp])
  end
end
