defmodule LLMProxy.Providers.Attempt do
  @moduledoc """
  Normalized provider deployment attempt used by routing, fallback, cache keys, and circuit breakers.
  """

  alias LLMProxy.Catalog.Deployment

  defstruct [
    :provider,
    :provider_name,
    :model,
    :token_pool,
    timeout_ms: nil,
    failure_threshold: nil,
    cooldown_ms: nil,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          provider: module(),
          provider_name: String.t(),
          model: String.t(),
          token_pool: String.t() | nil,
          timeout_ms: pos_integer() | nil,
          failure_threshold: pos_integer(),
          cooldown_ms: pos_integer(),
          metadata: map()
        }

  @spec new(Deployment.t() | {module(), String.t()} | t()) :: t()
  def new(%__MODULE__{} = attempt), do: attempt

  def new(%Deployment{} = deployment) do
    %__MODULE__{
      provider: deployment.provider,
      provider_name: deployment.provider_name,
      model: deployment.upstream_model,
      token_pool: deployment.token_pool,
      timeout_ms: deployment.timeout_ms,
      failure_threshold: deployment.failure_threshold,
      cooldown_ms: deployment.cooldown_ms,
      metadata: deployment.metadata
    }
  end

  def new({provider, model}) do
    %__MODULE__{
      provider: provider,
      provider_name: provider.name(),
      model: model,
      failure_threshold: LLMProxy.Config.deployment_failure_threshold(),
      cooldown_ms: LLMProxy.Config.deployment_cooldown_ms()
    }
  end

  @spec key(t()) :: {String.t(), String.t()}
  def key(%__MODULE__{provider: provider, provider_name: nil, model: model}) do
    {provider.name(), model}
  end

  def key(%__MODULE__{provider_name: provider_name, model: model}) do
    {provider_name, model}
  end
end
