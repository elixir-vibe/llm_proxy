defmodule LlmProxy.Providers.Registry do
  @moduledoc """
  Provider discovery via :persistent_term.

  Providers register themselves at application startup.
  Model→provider lookup is O(1).
  """

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
    model_index = :persistent_term.get(@model_index_key, %{})
    Map.get(model_index, model_id)
  end

  def all_models do
    providers = :persistent_term.get(@registry_key, %{})

    Enum.flat_map(providers, fn {name, module} ->
      Enum.map(module.models(), fn id ->
        %{id: id, object: "model", owned_by: name}
      end)
    end)
  end

  def list_providers do
    :persistent_term.get(@registry_key, %{})
  end
end
