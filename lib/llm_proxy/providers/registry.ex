defmodule LLMProxy.Providers.Registry do
  @moduledoc """
  Provider discovery via :persistent_term.

  Providers register themselves at application startup.
  Model→provider lookup is O(1).
  """

  alias LLMProxy.ProviderRouting.Attempt

  @registry_key :llm_proxy_providers
  @model_index_key :llm_proxy_model_index

  def init do
    :persistent_term.put(@registry_key, %{})
    :persistent_term.put(@model_index_key, %{})
  end

  def register(module) when is_atom(module) do
    name = module.name()
    models = module.models()

    providers = :persistent_term.get(@registry_key, %{})
    :persistent_term.put(@registry_key, Map.put(providers, name, module))

    model_index = :persistent_term.get(@model_index_key, %{})
    new_entries = Map.new(models, fn model_id -> {model_id, module} end)
    :persistent_term.put(@model_index_key, Map.merge(model_index, new_entries))

    :ok
  end

  def get_provider(model_id) when is_binary(model_id) do
    case resolve_model(model_id) do
      {:ok, {provider, _upstream_model}} -> provider
      :error -> nil
    end
  end

  def resolve_model(model_id) when is_binary(model_id) do
    case resolve_attempts(model_id) do
      {:ok, [%Attempt{provider: provider, model: upstream_model} | _]} ->
        {:ok, {provider, upstream_model}}

      :error ->
        :error
    end
  end

  def resolve_attempts(model_id) when is_binary(model_id) do
    case LLMProxy.Catalog.resolve_deployments(model_id) do
      {:ok, deployments} ->
        {:ok, Enum.map(deployments, &Attempt.new/1) ++ get_fallbacks(model_id)}

      :error ->
        model_index = :persistent_term.get(@model_index_key, %{})

        case Map.get(model_index, model_id) do
          nil -> :error
          provider -> {:ok, [Attempt.new({provider, model_id}) | get_fallbacks(model_id)]}
        end
    end
  end

  @doc """
  Returns fallback {provider_module, model_id} pairs for a model.

  Configured via `config :llm_proxy, :fallbacks`.
  Each fallback model must be registered with a provider.
  """
  def get_fallbacks(model_id) when is_binary(model_id) do
    fallback_models = Map.get(LLMProxy.Config.fallbacks(), model_id, [])

    for fb_model <- fallback_models,
        {:ok, {provider, upstream_model}} <- [resolve_model_without_fallbacks(fb_model)] do
      Attempt.new({provider, upstream_model})
    end
  end

  defp resolve_model_without_fallbacks(model_id) do
    case LLMProxy.Catalog.resolve(model_id) do
      {:ok, deployment} ->
        {:ok, {deployment.provider, deployment.upstream_model}}

      :error ->
        model_index = :persistent_term.get(@model_index_key, %{})

        case Map.get(model_index, model_id) do
          nil -> :error
          provider -> {:ok, {provider, model_id}}
        end
    end
  end

  def all_models do
    providers = :persistent_term.get(@registry_key, %{})

    provider_models =
      Enum.flat_map(providers, fn {name, module} ->
        Enum.map(module.models(), fn id ->
          %{id: id, object: "model", owned_by: name}
        end)
      end)

    LLMProxy.Catalog.all_models() ++ provider_models
  end

  def list_providers do
    :persistent_term.get(@registry_key, %{})
  end
end
