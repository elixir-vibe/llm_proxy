defmodule LLMProxy.Providers.OpenAICompatible.Definition do
  @moduledoc """
  Macro frontend for defining OpenAI-compatible upstream providers.

  The generated provider implements `LLMProxy.Providers.Behaviour` and delegates
  token selection, request execution, streaming, and usage extraction to the
  shared OpenAI-compatible client.
  """

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    models = Keyword.get(opts, :models)
    provider_id = Keyword.get(opts, :provider_id)
    config_key = Keyword.get(opts, :config_key, name)
    title = Keyword.get(opts, :title)
    referer = Keyword.get(opts, :http_referer)

    quote bind_quoted: [
            name: name,
            models: models,
            provider_id: provider_id,
            config_key: config_key,
            title: title,
            referer: referer
          ] do
      @behaviour LLMProxy.Providers.Behaviour

      alias LLMProxy.Providers.OpenAICompatible

      @provider_name name
      @provider_models models
      @provider_id provider_id
      @provider_config_key config_key
      @provider_title title
      @provider_referer referer

      @impl true
      def name, do: @provider_name

      @impl true
      def native_protocol, do: :openai

      @impl true
      if is_nil(@provider_models) do
        @impl true
        def models, do: LLMProxy.ModelDB.provider_model_ids(@provider_id)
      else
        @impl true
        def models, do: @provider_models
      end

      @impl true
      def call(body, user_id), do: OpenAICompatible.call(@provider_name, body, user_id, opts())

      def call(body, user_id, %LLMProxy.Providers.Attempt{token_pool: token_pool}) do
        OpenAICompatible.call(@provider_name, body, user_id, opts(token_pool))
      end

      @impl true
      def stream(body, user_id),
        do: OpenAICompatible.stream(@provider_name, body, user_id, opts())

      def stream(body, user_id, %LLMProxy.Providers.Attempt{token_pool: token_pool}) do
        OpenAICompatible.stream(@provider_name, body, user_id, opts(token_pool))
      end

      @impl true
      def extract_usage(response), do: OpenAICompatible.extract_usage(response)

      @impl true
      def to_openai_response(response, model), do: Map.put(response, "model", model)

      defp opts(token_pool \\ nil) do
        %{base_url_fn: &base_url/1, headers_fn: &headers/1, token_pool: token_pool}
      end

      defp headers(token) do
        [
          {"authorization", "Bearer #{token.token}"},
          {"content-type", "application/json"}
        ]
        |> maybe_put_header("http-referer", provider_value(:http_referer, @provider_referer))
        |> maybe_put_header("x-title", provider_value(:title, @provider_title))
      end

      defp maybe_put_header(headers, _name, nil), do: headers
      defp maybe_put_header(headers, _name, ""), do: headers
      defp maybe_put_header(headers, name, value), do: headers ++ [{name, value}]

      defp base_url(%{proxy: proxy}) when is_binary(proxy) and proxy != "", do: proxy
      defp base_url(_token), do: provider_value(:base_url)

      defp provider_value(key), do: LLMProxy.Config.provider_value(@provider_config_key, key)

      defp provider_value(key, default),
        do: LLMProxy.Config.provider_value(@provider_config_key, key, default)

      defoverridable models: 0,
                     headers: 1,
                     base_url: 1,
                     extract_usage: 1,
                     to_openai_response: 2
    end
  end
end
