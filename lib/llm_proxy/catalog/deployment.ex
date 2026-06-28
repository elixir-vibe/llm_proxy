defmodule LLMProxy.Catalog.Deployment do
  @moduledoc """
  Internal catalog deployment target for a public model alias.
  """

  @enforce_keys [:provider, :upstream_model]
  defstruct provider: nil,
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
    %__MODULE__{
      provider: Keyword.fetch!(attrs, :provider),
      upstream_model: Keyword.fetch!(attrs, :upstream_model),
      order: Keyword.get(attrs, :order, 1),
      token_pool: Keyword.get(attrs, :token_pool),
      timeout_ms: Keyword.get(attrs, :timeout_ms),
      failure_threshold:
        Keyword.get(attrs, :failure_threshold, LLMProxy.Config.deployment_failure_threshold()),
      cooldown_ms: Keyword.get(attrs, :cooldown_ms, LLMProxy.Config.deployment_cooldown_ms()),
      weight: Keyword.get(attrs, :weight, 1),
      metadata: Keyword.get(attrs, :metadata, %{})
    }
  end
end
