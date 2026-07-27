defmodule LLMProxy.Providers.ReqLLM.ErrorProjection do
  @moduledoc false

  alias LLMProxy.Protocol.Request.Error, as: RequestError

  @fallback_message "Upstream provider request failed"

  @transport_reasons [
    :econnrefused,
    :econnreset,
    :nxdomain,
    :timeout,
    :closed,
    :ENOTFOUND,
    :unreachable,
    :tls_alert,
    :certificate_expired
  ]

  @type t :: %{
          message: String.t(),
          code: String.t(),
          status: pos_integer()
        }

  @spec project(term()) :: t()
  def project(%QuackDB.Error{}) do
    projected_error("Internal stream processing failed", "internal_error", 500)
  end

  def project(reason) do
    chain = error_chain(reason)
    status = Enum.find_value(chain, &status/1) || 502

    projected_error(
      Enum.find_value(chain, &message/1) || @fallback_message,
      Enum.find_value(chain, &code/1) || status_code(status),
      status
    )
  end

  @spec accounting_error() :: t()
  def accounting_error, do: projected_error("Usage accounting failed", "accounting_error", 500)

  @spec client_error(term()) :: map()
  def client_error(reason) do
    error = project(reason)

    %{
      "message" => error.message,
      "type" => error.code,
      "code" => error.code,
      "status" => error.status
    }
  end

  defp projected_error(message, code, status),
    do: %{message: message, code: code, status: status}

  defp error_chain(reason), do: error_chain(reason, [], 0)

  defp error_chain(_reason, chain, 8), do: chain

  defp error_chain(reason, chain, depth) do
    chain = [reason | chain]

    case field(reason, :cause) do
      nil -> chain
      cause -> error_chain(cause, chain, depth + 1)
    end
  end

  defp message(%RequestError{message: message}), do: message

  defp message(error) do
    error
    |> field(:response_body)
    |> body_message()
    |> case do
      nil -> reason_message(error)
      message -> message
    end
  end

  # Synthetic stream errors stringify their cause with inspect/1. Project the
  # structured cause from the error chain instead of forwarding that wrapper.
  defp reason_message(%ReqLLM.Error.API.Stream{cause: cause}) when not is_nil(cause), do: nil

  # Surface the underlying transport reason (DNS failure, refused connection,
  # reset, TLS problem, timeout) instead of the opaque fallback so operators
  # can tell a dead upstream from a generic provider error.
  defp reason_message(%RuntimeError{message: message}), do: safe_reason(message)

  defp reason_message(error) do
    reason = field(error, :reason) || field(error, :original) || error

    cond do
      message = websocket_close_message(reason) -> message
      reason in @transport_reasons -> "Connection error: #{reason}"
      transport_reason?(reason) -> "Connection error: #{reason}"
      true -> safe_reason(reason)
    end
  end

  defp websocket_close_message({side, code, _detail})
       when side in [:local, :remote] and is_integer(code),
       do: "WebSocket closed #{code}"

  defp websocket_close_message(_reason), do: nil

  defp transport_reason?(reason) when is_atom(reason) do
    reason
    |> Atom.to_string()
    |> String.contains?([
      "conn",
      "closed",
      "reset",
      "refused",
      "timeout",
      "nxdomain",
      "unreachable"
    ])
  end

  defp transport_reason?(reason) when is_binary(reason) do
    String.contains?(reason, [
      "conn",
      "closed",
      "reset",
      "refused",
      "timeout",
      "nxdomain",
      "unreachable"
    ])
  end

  defp transport_reason?(_reason), do: false

  defp code(%RequestError{code: code}), do: code

  defp code(error) do
    field(error, :provider_code) ||
      error |> field(:response_body) |> body_code()
  end

  defp status(%RequestError{}), do: 400

  defp status(error) do
    case field(error, :status) || field(error, :status_code) do
      status when is_integer(status) and status >= 400 and status <= 599 -> status
      _other -> nil
    end
  end

  defp body_message(%{"message" => message}) when is_binary(message), do: message
  defp body_message(%{message: message}) when is_binary(message), do: message
  defp body_message(%{"error" => error}) when is_map(error), do: body_message(error)
  defp body_message(%{error: error}) when is_map(error), do: body_message(error)
  defp body_message(_body), do: nil

  defp body_code(%{"type" => code}) when is_binary(code), do: code
  defp body_code(%{type: code}) when is_binary(code), do: code
  defp body_code(%{"code" => code}) when is_binary(code), do: code
  defp body_code(%{code: code}) when is_binary(code), do: code
  defp body_code(%{"error" => error}) when is_map(error), do: body_code(error)
  defp body_code(%{error: error}) when is_map(error), do: body_code(error)
  defp body_code(_body), do: nil

  defp safe_reason(reason) when is_binary(reason) do
    if String.contains?(reason, ["%ReqLLM.", "#Splode", "headers:"]) do
      nil
    else
      reason
    end
  end

  defp safe_reason(_reason), do: nil

  defp status_code(401), do: "authentication_error"
  defp status_code(403), do: "permission_error"
  defp status_code(429), do: "rate_limit_error"
  defp status_code(status) when is_integer(status) and status >= 500, do: "upstream_error"
  defp status_code(_status), do: "api_error"

  defp field(%{} = value, key), do: Map.get(value, key) || Map.get(value, Atom.to_string(key))
  defp field(_value, _key), do: nil
end
