defmodule LLMProxy.ModelDB do
  @moduledoc false

  @provider_ids %{
    "anthropic" => :anthropic,
    "openai" => :openai,
    "openai-codex" => :openai_codex,
    "openrouter" => :openrouter
  }

  @known_providers [:openai, :openai_codex, :anthropic, :openrouter]

  @spec provider_id(module() | atom() | String.t() | nil) :: atom() | nil
  def provider_id(nil), do: nil
  def provider_id(provider) when is_binary(provider), do: Map.get(@provider_ids, provider)

  def provider_id(provider) when is_atom(provider) do
    cond do
      provider in Map.values(@provider_ids) -> provider
      function_exported?(provider, :name, 0) -> provider_id(provider.name())
      true -> nil
    end
  end

  @spec provider_model_ids(atom() | String.t()) :: [String.t()]
  def provider_model_ids(provider) do
    provider
    |> provider_id()
    |> case do
      nil -> []
      provider_id -> provider_id |> LLMDB.models() |> Enum.map(&model_id/1) |> Enum.sort()
    end
  rescue
    _error in [ArgumentError, RuntimeError] -> []
  end

  @spec pricing(String.t(), module() | atom() | String.t() | nil) :: map() | nil
  def pricing(model, provider \\ nil) when is_binary(model) do
    case find_model(model, provider) do
      {:ok, llm_db_model} ->
        llm_db_model
        |> cost_from_model()
        |> case do
          nil -> cost_from_pricing_components(llm_db_model.pricing)
          cost -> cost
        end

      _error ->
        nil
    end
  end

  defp find_model(model, provider) do
    case provider_id(provider) do
      nil -> find_model_without_provider(model)
      provider_id -> LLMDB.model(provider_id, model)
    end
  end

  defp find_model_without_provider(model) do
    case LLMDB.model(model) do
      {:ok, _model} = ok -> ok
      {:error, _reason} -> find_model_in_known_providers(model)
    end
  rescue
    _error in [ArgumentError, RuntimeError] -> find_model_in_known_providers(model)
  end

  defp find_model_in_known_providers(model) do
    Enum.find_value(@known_providers, {:error, :not_found}, fn provider ->
      case LLMDB.model(provider, model) do
        {:ok, _model} = ok -> ok
        {:error, _reason} -> nil
      end
    end)
  end

  defp model_id(%{model: model}) when is_binary(model), do: model
  defp model_id(%{id: id}), do: id

  defp cost_from_model(%{cost: cost}) when is_map(cost) do
    %{
      "input" => Map.get(cost, :input) || Map.get(cost, "input") || 0,
      "output" => Map.get(cost, :output) || Map.get(cost, "output") || 0,
      "cache_read" => Map.get(cost, :cache_read) || Map.get(cost, "cache_read") || 0,
      "cache_write" => Map.get(cost, :cache_write) || Map.get(cost, "cache_write") || 0
    }
  end

  defp cost_from_model(_model), do: nil

  defp cost_from_pricing_components(%{components: components}) when is_list(components) do
    Enum.reduce(components, zero_cost(), fn component, acc ->
      case {Map.get(component, :kind) || Map.get(component, "kind"),
            Map.get(component, :id) || Map.get(component, "id")} do
        {"token", "token.input"} -> put_rate(acc, "input", component)
        {"token", "token.output"} -> put_rate(acc, "output", component)
        {"token", "token.cache_read"} -> put_rate(acc, "cache_read", component)
        {"token", "token.cache_write"} -> put_rate(acc, "cache_write", component)
        _other -> acc
      end
    end)
  end

  defp cost_from_pricing_components(_pricing), do: nil

  defp zero_cost, do: %{"input" => 0, "output" => 0, "cache_read" => 0, "cache_write" => 0}

  defp put_rate(cost, key, component) do
    per = Map.get(component, :per) || Map.get(component, "per") || 1
    rate = Map.get(component, :rate) || Map.get(component, "rate") || 0
    Map.put(cost, key, rate * 1_000_000 / per)
  end
end
