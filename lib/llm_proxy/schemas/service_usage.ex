defmodule LLMProxy.Schemas.ServiceUsage do
  @moduledoc """
  Ecto schema for non-provider service usage counters tied to an API key and endpoint.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "service_usage_log" do
    field(:key_id, :string)
    field(:service, :string)
    field(:endpoint, :string)
    field(:timestamp, :utc_datetime)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:key_id, :service, :endpoint, :timestamp])
    |> validate_required([:key_id, :service, :endpoint, :timestamp])
  end
end
