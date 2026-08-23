defmodule LLMProxy.ProviderUsage.HTTP do
  @moduledoc false

  alias LLMProxy.ProviderUsage.Source

  @spec get(Source.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, map()} | {:error, atom()}
  def get(%Source{} = source, path, headers) do
    with {:ok, url} <- url(source.base_url, path) do
      timeout = LLMProxy.Config.provider_usage_request_timeout_ms()

      request =
        LLMProxy.HTTP.new(
          url: url,
          headers: headers,
          connect_options: [timeout: timeout],
          receive_timeout: timeout,
          finch: [pool_timeout: timeout],
          retry: false,
          redirect: false
        )

      case Req.get(request) do
        {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
        {:ok, %{status: 200}} -> {:error, :invalid_response}
        {:ok, %{status: status}} -> {:error, status_error(status)}
        {:error, exception} -> {:error, exception_error(exception)}
      end
    end
  end

  defp url(base_url, path) when is_binary(base_url) and is_binary(path) do
    case URI.parse(base_url) do
      %URI{scheme: "https", host: host, userinfo: nil} = uri
      when is_binary(host) and host != "" ->
        {:ok,
         uri
         |> Map.put(:path, path)
         |> Map.put(:query, nil)
         |> Map.put(:fragment, nil)
         |> URI.to_string()}

      _other ->
        {:error, :invalid_configuration}
    end
  end

  defp url(_base_url, _path), do: {:error, :invalid_configuration}

  defp status_error(status) when status in [401, 403], do: :authentication_failed
  defp status_error(404), do: :not_found
  defp status_error(408), do: :timeout
  defp status_error(429), do: :rate_limited
  defp status_error(status) when status in 500..599, do: :unavailable
  defp status_error(_status), do: :invalid_response

  defp exception_error(%{reason: reason}) when reason in [:timeout, :connect_timeout],
    do: :timeout

  defp exception_error(_exception), do: :unavailable
end
