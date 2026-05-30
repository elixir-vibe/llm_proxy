defmodule LLMProxy.Routing.Attempt do
  @moduledoc false

  alias LLMProxy.Catalog.Deployment

  @default_failure_threshold 3
  @default_cooldown_ms 30_000

  defstruct [
    :provider,
    :model,
    timeout_ms: nil,
    failure_threshold: @default_failure_threshold,
    cooldown_ms: @default_cooldown_ms,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          provider: module(),
          model: String.t(),
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
      model: deployment.upstream_model,
      timeout_ms: deployment.timeout_ms,
      failure_threshold: deployment.failure_threshold,
      cooldown_ms: deployment.cooldown_ms,
      metadata: deployment.metadata
    }
  end

  def new({provider, model}) do
    %__MODULE__{provider: provider, model: model}
  end

  @spec key(t()) :: {String.t(), String.t()}
  def key(%__MODULE__{provider: provider, model: model}) do
    {provider.name(), model}
  end
end
