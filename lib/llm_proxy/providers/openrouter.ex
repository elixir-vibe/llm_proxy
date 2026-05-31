defmodule LLMProxy.Providers.OpenRouter do
  @moduledoc false

  @behaviour LLMProxy.Providers.Behaviour

  alias LLMProxy.Protocol.OpenAI, as: OpenAIProtocol
  alias LLMProxy.Providers.OpenAICompatible

  @impl true
  def name, do: "openrouter"

  @impl true
  def native_protocol, do: :openai

  @impl true
  def models, do: LLMProxy.ModelDB.provider_model_ids(:openrouter)

  @impl true
  def call(body, user_id), do: OpenAICompatible.call("openrouter", body, user_id, opts())

  @impl true
  def stream(body, user_id), do: OpenAICompatible.stream("openrouter", body, user_id, opts())

  @impl true
  def extract_usage(response), do: OpenAIProtocol.extract_usage(response)

  @impl true
  def to_openai_response(response, model), do: response |> Map.put("model", model)

  defp opts, do: %{base_url_fn: &base_url/1, headers_fn: &headers/1}

  defp headers(token) do
    [
      {"authorization", "Bearer #{token.token}"},
      {"http-referer", LLMProxy.Config.provider_value("openrouter", :http_referer)},
      {"x-title", LLMProxy.Config.provider_value("openrouter", :title)},
      {"content-type", "application/json"}
    ]
  end

  defp base_url(%{proxy: proxy}) when is_binary(proxy) and proxy != "", do: proxy
  defp base_url(_token), do: LLMProxy.Config.provider_value("openrouter", :base_url)
end
