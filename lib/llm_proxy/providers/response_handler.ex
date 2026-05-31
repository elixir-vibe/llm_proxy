defmodule LLMProxy.Providers.ResponseHandler do
  @moduledoc false

  alias LLMProxy.Providers.{Errors, Result}

  def post(req, body, token) do
    case Req.post(req, json: body) do
      {:ok, %{status: 200, body: response}} -> {:ok, Result.response(response, token)}
      {:ok, response} -> Errors.handle_response(token, response)
      {:error, exception} -> Errors.handle_exception(exception)
    end
  end
end
