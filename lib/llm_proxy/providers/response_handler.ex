defmodule LLMProxy.Providers.ResponseHandler do
  @moduledoc false

  alias LLMProxy.Providers.{ProviderError, Result}

  def post(req, body, token) do
    case Req.post(req, json: body) do
      {:ok, %{status: 200, body: response}} -> {:ok, Result.response(response, token)}
      {:ok, response} -> ProviderError.handle_response(token, response)
      {:error, exception} -> ProviderError.handle_exception(exception)
    end
  end
end
