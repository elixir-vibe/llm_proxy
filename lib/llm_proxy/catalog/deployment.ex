defmodule LLMProxy.Catalog.Deployment do
  @moduledoc false

  defstruct [
    :provider,
    :upstream_model,
    order: 1,
    token_pool: nil,
    timeout_ms: nil,
    failure_threshold: 3,
    cooldown_ms: 30_000,
    weight: 1,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          provider: module(),
          upstream_model: String.t(),
          order: pos_integer(),
          token_pool: String.t() | nil,
          timeout_ms: pos_integer() | nil,
          failure_threshold: pos_integer(),
          cooldown_ms: pos_integer(),
          weight: pos_integer(),
          metadata: map()
        }

  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      provider: fetch!(attrs, :provider, "provider"),
      upstream_model: fetch!(attrs, :upstream_model, "upstream_model"),
      order: get(attrs, :order, "order", 1),
      token_pool: get(attrs, :token_pool, "token_pool", nil),
      timeout_ms: get(attrs, :timeout_ms, "timeout_ms", nil),
      failure_threshold: get(attrs, :failure_threshold, "failure_threshold", 3),
      cooldown_ms: get(attrs, :cooldown_ms, "cooldown_ms", 30_000),
      weight: get(attrs, :weight, "weight", 1),
      metadata: get(attrs, :metadata, "metadata", %{})
    }
  end

  defp fetch!(attrs, atom_key, string_key) do
    Map.get(attrs, atom_key) || Map.fetch!(attrs, string_key)
  end

  defp get(attrs, atom_key, string_key, default) do
    Map.get(attrs, atom_key, Map.get(attrs, string_key, default))
  end
end
