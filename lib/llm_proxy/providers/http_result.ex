defmodule LLMProxy.Providers.HTTPResult do
  @moduledoc """
  Converts upstream HTTP responses and exceptions into `LLMProxy.Providers.Result` values.
  """

  alias LLMProxy.Providers.ReqLLM.ErrorProjection
  alias LLMProxy.Providers.Result
  alias LLMProxy.TokenPool.Server, as: TokenPool

  def post(req, body, token, model \\ nil) do
    case Req.post(req, json: body) do
      {:ok, %{status: 200, body: response}} -> {:ok, Result.response(response, token)}
      {:ok, response} -> handle_response(token, response, model)
      {:error, exception} -> handle_exception(exception)
    end
  end

  def handle_response(token, response, model \\ nil)

  def handle_response(token, %{status: status, body: body, headers: headers}, model) do
    retry_after_ms = retry_after_ms(headers)

    mark_rate_limited(status, token, model, retry_after_ms)

    result(extract(body), status, token,
      retry_after_ms: retry_after_ms,
      provider_body: provider_details(body)
    )
  end

  def handle_response(token, status, body) do
    mark_rate_limited(status, token, nil, nil)
    result(extract(body), status, token, provider_body: provider_details(body))
  end

  def handle_exception(exception) do
    error = ErrorProjection.project(exception)

    result(error.message, error.status, nil,
      replay_safety: ErrorProjection.replay_safety(exception),
      provider_body: %{"error" => ErrorProjection.client_error(exception)}
    )
  end

  def result(error, status, token, opts \\ []) do
    {:error, Result.error(error, status, token, opts)}
  end

  def retry_after_ms(headers) do
    headers
    |> Map.get("retry-after", [])
    |> List.first()
    |> parse_retry_after()
  end

  def provider_details(%{"error" => error}), do: error
  def provider_details(body), do: body

  def extract(%{"error" => %{"message" => message}}), do: message
  def extract(%{"error" => message}) when is_binary(message), do: message
  def extract(body) when is_binary(body), do: body
  def extract(_body), do: "Upstream provider request failed"

  defp mark_rate_limited(429, token, model, retry_after_ms)
       when not is_nil(token) and is_binary(model) do
    TokenPool.mark_rate_limited(
      token,
      model,
      retry_after_ms || LLMProxy.Config.token_cooldown_ms()
    )
  end

  defp mark_rate_limited(429, token, _model, retry_after_ms) when not is_nil(token) do
    TokenPool.mark_rate_limited(token, retry_after_ms || LLMProxy.Config.token_cooldown_ms())
  end

  defp mark_rate_limited(_status, _token, _model, _retry_after_ms), do: :ok

  defp parse_retry_after(nil), do: nil

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _other -> nil
    end
  end
end
