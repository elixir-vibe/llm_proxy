defmodule LLMProxy.Providers.ReqLLM.RetryHeaders do
  @moduledoc false

  # ReqLLM's provider decoders can replace an HTTP error with API.Response,
  # losing its headers. Preserve 429 metadata before that decoder runs.
  def attach(request) do
    Req.Request.append_response_steps(request, provider_retry_headers: &preserve/1)
  end

  defp preserve({request, %Req.Response{status: 429} = response}) do
    error =
      ReqLLM.Error.API.Request.exception(
        reason: "Upstream rate limited",
        status: response.status,
        response_body: response.body,
        headers: response.headers
      )

    {request, error}
  end

  defp preserve(request_response), do: request_response
end
