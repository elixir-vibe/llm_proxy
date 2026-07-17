defmodule LLMProxy.Catalog.Deployment do
  @moduledoc """
  Internal catalog deployment target for a public model alias.
  """

  @enforce_keys [:provider, :upstream_model]
  defstruct provider: nil,
            provider_name: nil,
            upstream_model: nil,
            order: 1,
            token_pool: nil,
            timeout_ms: nil,
            failure_threshold: nil,
            cooldown_ms: nil,
            weight: 1,
            metadata: %{}

  @type t :: %__MODULE__{
          provider: module(),
          provider_name: String.t(),
          upstream_model: String.t(),
          order: pos_integer(),
          token_pool: String.t() | nil,
          timeout_ms: pos_integer() | nil,
          failure_threshold: pos_integer(),
          cooldown_ms: pos_integer(),
          weight: pos_integer(),
          metadata: map()
        }

  @spec new!(keyword()) :: t()
  def new!(attrs) when is_list(attrs) do
    provider = Keyword.fetch!(attrs, :provider)
    upstream_model = Keyword.fetch!(attrs, :upstream_model)
    provider_name = Keyword.get(attrs, :provider_name) || default_provider_name(provider)
    order = Keyword.get(attrs, :order, 1)
    timeout_ms = Keyword.get(attrs, :timeout_ms)

    failure_threshold =
      Keyword.get(attrs, :failure_threshold) || LLMProxy.Config.deployment_failure_threshold()

    cooldown_ms = Keyword.get(attrs, :cooldown_ms) || LLMProxy.Config.deployment_cooldown_ms()
    weight = Keyword.get(attrs, :weight, 1)
    metadata = Keyword.get(attrs, :metadata, %{})

    validate_provider!(provider)
    validate_non_empty_string!(:provider_name, provider_name)
    validate_non_empty_string!(:upstream_model, upstream_model)
    validate_positive_integer!(:order, order)
    validate_optional_positive_integer!(:timeout_ms, timeout_ms)
    validate_positive_integer!(:failure_threshold, failure_threshold)
    validate_non_negative_integer!(:cooldown_ms, cooldown_ms)
    validate_positive_integer!(:weight, weight)
    validate_map!(:metadata, metadata)

    %__MODULE__{
      provider: provider,
      provider_name: provider_name,
      upstream_model: upstream_model,
      order: order,
      token_pool: Keyword.get(attrs, :token_pool),
      timeout_ms: timeout_ms,
      failure_threshold: failure_threshold,
      cooldown_ms: cooldown_ms,
      weight: weight,
      metadata: metadata
    }
  end

  defp default_provider_name(provider) do
    if function_exported?(provider, :name, 0), do: provider.name(), else: Atom.to_string(provider)
  end

  defp validate_provider!(provider) when is_atom(provider), do: :ok

  defp validate_provider!(provider) do
    raise ArgumentError,
          "catalog deployment provider must be a module atom, got: #{inspect(provider)}"
  end

  defp validate_non_empty_string!(_field, value) when is_binary(value) and value != "", do: :ok

  defp validate_non_empty_string!(field, value) do
    raise ArgumentError,
          "catalog deployment #{field} must be a non-empty string, got: #{inspect(value)}"
  end

  defp validate_positive_integer!(_field, value) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_integer!(field, value) do
    raise ArgumentError,
          "catalog deployment #{field} must be a positive integer, got: #{inspect(value)}"
  end

  defp validate_optional_positive_integer!(_field, nil), do: :ok

  defp validate_optional_positive_integer!(field, value),
    do: validate_positive_integer!(field, value)

  defp validate_non_negative_integer!(_field, value) when is_integer(value) and value >= 0,
    do: :ok

  defp validate_non_negative_integer!(field, value) do
    raise ArgumentError,
          "catalog deployment #{field} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp validate_map!(_field, value) when is_map(value), do: :ok

  defp validate_map!(field, value) do
    raise ArgumentError, "catalog deployment #{field} must be a map, got: #{inspect(value)}"
  end
end
