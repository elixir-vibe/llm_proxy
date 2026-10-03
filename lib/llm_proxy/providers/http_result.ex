defmodule LLMProxy.Providers.HTTPResult do
  @moduledoc """
  Converts upstream HTTP responses and exceptions into `LLMProxy.Providers.Result` values.
  Cooldowns are recorded at the provider execution boundary, not during conversion.
  """

  alias LLMProxy.Providers.{RateLimit, Result}
  alias LLMProxy.Providers.ReqLLM.ErrorProjection

  def post(req, body, token, model \\ nil) do
    case Req.post(req, json: body) do
      {:ok, %{status: 200, body: response}} -> {:ok, Result.response(response, token)}
      {:ok, response} -> handle_response(token, response, model)
      {:error, exception} -> handle_exception(exception)
    end
  end

  def handle_response(token, response, model \\ nil)

  def handle_response(token, %{status: status, body: body, headers: headers}, model) do
    result(extract(body), status, token,
      model: model,
      retry_after_ms: retry_after_ms(headers),
      rate_limit_kind: ErrorProjection.rate_limit_kind(%{status: status, response_body: body}),
      provider_body: provider_details(body)
    )
  end

  def handle_response(token, status, body) do
    result(extract(body), status, token,
      rate_limit_kind: ErrorProjection.rate_limit_kind(%{status: status, response_body: body}),
      provider_body: provider_details(body)
    )
  end

  def handle_exception(exception) do
    {:error, ErrorProjection.result(exception, nil)}
  end

  def result(error, status, token, opts \\ []) do
    {:error, Result.error(error, status, token, opts)}
  end

  defdelegate retry_after_ms(headers), to: RateLimit

  def provider_details(%{"error" => error}), do: error
  def provider_details(body), do: body

  def extract(%{"error" => %{"message" => message}}), do: message
  def extract(%{"error" => message}) when is_binary(message), do: message
  def extract(body) when is_binary(body), do: body
  def extract(_body), do: "Upstream provider request failed"
end
