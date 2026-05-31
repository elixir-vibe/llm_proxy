defmodule LLMProxy.Providers.OpenAICompatible do
  @moduledoc false

  alias LLMProxy.HTTP
  alias LLMProxy.Protocol.OpenAI
  alias LLMProxy.Providers.{Errors, OpenAIStream, ResponseHandler, Result, SSE, TokenAccess}

  def call(provider_name, body, user_id, opts) do
    with {:ok, token} <- TokenAccess.pick_token(provider_name, user_id) do
      req = request(token, opts, into: nil)

      ResponseHandler.post(req, body, token)
    end
  end

  def stream(provider_name, body, user_id, opts) do
    with {:ok, token} <- TokenAccess.pick_token(provider_name, user_id) do
      req = request(token, opts, into: :self)
      body = Map.put(body, "stream", true)

      case Req.post(req, json: body) do
        {:ok, %{status: 200} = response} ->
          stream =
            response.body
            |> SSE.parse_events()
            |> Stream.map(&OpenAIStream.to_event/1)
            |> Stream.reject(&is_nil/1)

          {:ok, Result.stream(stream, token)}

        {:ok, response} ->
          Errors.handle_response(token, response)

        {:error, exception} ->
          Errors.handle_exception(exception)
      end
    end
  end

  def extract_usage(response), do: OpenAI.extract_usage(response)

  defp request(token, opts, into: into) do
    HTTP.new(
      url: "#{opts.base_url_fn.(token)}/chat/completions",
      headers: opts.headers_fn.(token),
      receive_timeout: LLMProxy.Config.provider_receive_timeout_ms()
    )
    |> maybe_put_into(into)
  end

  defp maybe_put_into(req, nil), do: req
  defp maybe_put_into(req, into), do: Req.Request.put_option(req, :into, into)
end
