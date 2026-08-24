defmodule LLMProxy.Schemas.ApiKey do
  @moduledoc """
  Ecto schema for LLMProxy API keys, quotas, budgets, content policy, model access,
  and aggregate usage counters.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "api_keys" do
    field(:hash, :string)
    field(:name, :string)
    field(:enabled, :boolean, default: true)
    field(:quota_4h_input, :integer)
    field(:quota_4h_output, :integer)
    field(:quota_week_input, :integer)
    field(:quota_week_output, :integer)
    field(:quota_4h_messages, :integer)
    field(:quota_week_messages, :integer)
    field(:min_cache_ratio, :float)
    field(:allowed_models, LLMProxy.Storage.JSON)
    field(:service_quotas, LLMProxy.Storage.JSON)
    field(:total_spend_usd, :float, default: 0.0)
    field(:max_budget_usd, :float)
    field(:budget_period, :string)
    field(:budget_limits, LLMProxy.Storage.JSON)
    field(:trace_requests, :boolean, default: false)
    field(:capture_content, :boolean, default: false)
    field(:input_tokens, :integer, default: 0)
    field(:output_tokens, :integer, default: 0)
    field(:cache_read_tokens, :integer, default: 0)
    field(:cache_write_tokens, :integer, default: 0)

    timestamps(type: :utc_datetime)
  end

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [
      :id,
      :hash,
      :name,
      :enabled,
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
      :budget_limits,
      :trace_requests,
      :capture_content,
      :input_tokens,
      :output_tokens,
      :cache_read_tokens,
      :cache_write_tokens
    ])
    |> validate_required([:id, :hash, :name])
    |> validate_number(:quota_4h_input, greater_than_or_equal_to: 0)
    |> validate_number(:quota_4h_output, greater_than_or_equal_to: 0)
    |> validate_number(:quota_week_input, greater_than_or_equal_to: 0)
    |> validate_number(:quota_week_output, greater_than_or_equal_to: 0)
    |> validate_number(:quota_4h_messages, greater_than_or_equal_to: 0)
    |> validate_number(:quota_week_messages, greater_than_or_equal_to: 0)
    |> validate_number(:min_cache_ratio, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> validate_number(:total_spend_usd, greater_than_or_equal_to: 0)
    |> validate_number(:max_budget_usd, greater_than_or_equal_to: 0)
    |> validate_inclusion(:budget_period, ["4h", "week"], allow_nil: true)
    |> validate_change(:budget_limits, fn :budget_limits, limits ->
      if LLMProxy.Limit.valid?(limits),
        do: [],
        else: [budget_limits: "has invalid limit definitions"]
    end)
    |> normalize_budget_limits()
    |> unique_constraint(:hash)
  end

  defp normalize_budget_limits(changeset) do
    case get_change(changeset, :budget_limits) do
      nil ->
        changeset

      limits ->
        case LLMProxy.Limit.normalize(limits) do
          {:ok, normalized} ->
            put_change(changeset, :budget_limits, Enum.map(normalized, &Map.from_struct/1))

          {:error, _reason} ->
            changeset
        end
    end
  end
end
