defmodule LLMProxy.Providers.ResponseHandler do
  @moduledoc """
  Converts upstream provider HTTP results into `LLMProxy.Providers.Result` values.
  """

  alias LLMProxy.Providers.Result
  alias LLMProxy.TokenPool.Server, as: TokenPool

  def post(req, body, token) do
    case Req.post(req, json: body) do
      {:ok, %{status: 200, body: response}} -> {:ok, Result.response(response, token)}
      {:ok, response} -> handle_response(token, response)
      {:error, exception} -> handle_exception(exception)
    end
  end

  def handle_response(token, %{status: status, body: body, headers: headers}) do
    retry_after_ms = retry_after_ms(headers)

    if status == 429,
      do:
        TokenPool.mark_rate_limited(token, retry_after_ms || LLMProxy.Config.token_cooldown_ms())

    result(extract(body), status, token, retry_after_ms: retry_after_ms)
  end

  def handle_response(token, status, body) do
    if status == 429, do: TokenPool.mark_rate_limited(token)
    result(extract(body), status, token)
  end

  def handle_exception(exception) do
    result(Exception.message(exception), 502, nil)
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

  def extract(%{"error" => %{"message" => message}}), do: message
  def extract(%{"error" => message}) when is_binary(message), do: message
  def extract(body) when is_binary(body), do: body
  def extract(body), do: inspect(body)

  defp parse_retry_after(nil), do: nil

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _other -> nil
    end
  end
end
