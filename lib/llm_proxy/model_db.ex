defmodule LLMProxy.ModelDB do
  @moduledoc false

  @known_providers [:openai, :openai_codex, :anthropic, :openrouter]

  @spec provider_id(module() | atom() | nil) :: atom() | nil
  def provider_id(nil), do: nil
  def provider_id(:openai), do: :openai
  def provider_id(:openai_codex), do: :openai_codex
  def provider_id(:anthropic), do: :anthropic
  def provider_id(:openrouter), do: :openrouter
  def provider_id(LLMProxy.Providers.OpenAI), do: :openai
  def provider_id(LLMProxy.Providers.OpenAICodex), do: :openai_codex
  def provider_id(LLMProxy.Providers.Anthropic), do: :anthropic
  def provider_id(LLMProxy.Providers.OpenRouter), do: :openrouter
  def provider_id(_provider), do: nil

  @spec provider_model_ids(atom()) :: [String.t()]
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

  @spec pricing(String.t(), module() | atom() | nil) :: LLMProxy.Pricing.Rates.t() | nil
  def pricing(model, provider \\ nil) when is_binary(model) do
    case find_model(model, provider) do
      {:ok, llm_db_model} -> rates_from_model(llm_db_model)
      {:error, _reason} -> nil
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

  defp rates_from_model(%{pricing: %{components: components}}) when is_list(components) do
    Enum.reduce(components, LLMProxy.Pricing.Rates.zero(), &put_component_rate/2)
  end

  defp rates_from_model(%{cost: cost}) when is_map(cost) do
    LLMProxy.Pricing.Rates.new(
      input: cost.input || 0,
      output: cost.output || 0,
      cache_read: cost.cache_read || 0,
      cache_write: cost.cache_write || 0
    )
  end

  defp rates_from_model(_model), do: nil

  defp put_component_rate(%{kind: "token", id: "token.input"} = component, rates),
    do: put_rate(rates, :input, component)

  defp put_component_rate(%{kind: "token", id: "token.output"} = component, rates),
    do: put_rate(rates, :output, component)

  defp put_component_rate(%{kind: "token", id: "token.cache_read"} = component, rates),
    do: put_rate(rates, :cache_read, component)

  defp put_component_rate(%{kind: "token", id: "token.cache_write"} = component, rates),
    do: put_rate(rates, :cache_write, component)

  defp put_component_rate(_component, rates), do: rates

  defp put_rate(rates, key, %{per: per, rate: rate}) when is_number(per) and is_number(rate) do
    LLMProxy.Pricing.Rates.put(rates, key, rate * 1_000_000 / per)
  end

  defp put_rate(rates, _key, _component), do: rates
end
