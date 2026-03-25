defmodule LLMProxy.Schemas.ApiKey do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "api_keys" do
    field :hash, :string
    field :name, :string
    field :quota_4h_input, :integer
    field :quota_4h_output, :integer
    field :quota_week_input, :integer
    field :quota_week_output, :integer
    field :quota_4h_messages, :integer
    field :quota_week_messages, :integer
    field :min_cache_ratio, :float
    field :allowed_models, {:array, :string}
    field :service_quotas, :map
    field :total_spend_usd, :float, default: 0.0
    field :max_budget_usd, :float
    field :budget_period, :string
    field :trace_requests, :boolean, default: false
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cache_read_tokens, :integer, default: 0
    field :cache_write_tokens, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [
      :id,
      :hash,
      :name,
      :quota_4h_input,
      :quota_4h_output,
      :quota_week_input,
      :quota_week_output,
      :quota_4h_messages,
      :quota_week_messages,
      :min_cache_ratio,
      :allowed_models,
      :service_quotas,
      :total_spend_usd,
      :max_budget_usd,
      :budget_period,
      :trace_requests,
      :input_tokens,
      :output_tokens,
      :cache_read_tokens,
      :cache_write_tokens
    ])
    |> validate_required([:id, :hash, :name])
    |> unique_constraint(:hash)
  end
end
