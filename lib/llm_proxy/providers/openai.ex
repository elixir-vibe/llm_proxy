defmodule LLMProxy.Providers.OpenAI do
  @moduledoc false

  @behaviour LLMProxy.Providers.Behaviour

  alias LLMProxy.Providers.OpenAICompatible

  @impl true
  def name, do: "openai"

  @impl true
  def native_protocol, do: :openai

  @impl true
  def models, do: LLMProxy.ModelDB.provider_model_ids(:openai)

  @impl true
  def call(body, user_id), do: OpenAICompatible.call("openai", body, user_id, opts())

  @impl true
  def stream(body, user_id), do: OpenAICompatible.stream("openai", body, user_id, opts())

  @impl true
  def extract_usage(response), do: OpenAICompatible.extract_usage(response)

  @impl true
  def to_openai_response(response, model), do: Map.put(response, "model", model)

  defp opts do
    %{base_url_fn: &base_url/1, headers_fn: &headers/1}
  end

  defp headers(token) do
    [
      {"authorization", "Bearer #{token.token}"},
      {"content-type", "application/json"}
    ]
  end

  defp base_url(%{proxy: proxy}) when is_binary(proxy) and proxy != "", do: proxy
  defp base_url(_token), do: LLMProxy.Config.provider_value("openai", :base_url)
end
