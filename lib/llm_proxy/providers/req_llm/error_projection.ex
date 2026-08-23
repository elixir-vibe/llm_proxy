defmodule LLMProxy.Providers.ReqLLM.ErrorProjection do
  @moduledoc false

  alias LLMProxy.Protocol.Request.Error, as: RequestError

  @fallback_message "Upstream provider request failed"
  @max_message_length 2_000

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

  @safe_transport_reasons [
    :econnrefused,
    :nxdomain,
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

  @spec replay_safety(term()) :: LLMProxy.Providers.Result.replay_safety()
  def replay_safety(%ReqLLM.Error.API.Timeout{kind: :connect}), do: :safe
  def replay_safety(%ReqLLM.Error.API.Timeout{}), do: :uncertain
  def replay_safety(%WebSockex.RequestError{}), do: :safe

  def replay_safety(reason) do
    chain = error_chain(reason)

    {result_status, safe_transport?} =
      Enum.reduce(chain, {nil, false}, fn item, {result_status, safe_transport?} ->
        {result_status || status(item), safe_transport? || safe_transport_reason?(item)}
      end)

    cond do
      result_status == 429 -> :safe
      safe_transport? -> :safe
      is_integer(result_status) and result_status < 500 -> :forbidden
      true -> :uncertain
    end
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
    do: %{message: message, code: safe_code(code, status_code(status)), status: status}

  defp error_chain(reason), do: error_chain(reason, [], 0)

  defp error_chain(_reason, chain, 8), do: chain

  defp error_chain(reason, chain, depth) do
    chain = [reason | chain]

    case field(reason, :cause) do
      nil -> chain
      cause -> error_chain(cause, chain, depth + 1)
    end
  end

  defp message(%RequestError{message: message}), do: safe_reason(message)

  defp message(%ReqLLM.Error.API.Timeout{} = error),
    do: error |> Exception.message() |> safe_reason()

  defp message(%WebSockex.RequestError{message: message}) when is_binary(message),
    do: safe_reason("WebSocket handshake failed: #{message}")

  defp message({:websocket_error_event, event}) when is_map(event) do
    event
    |> provider_event_body()
    |> body_message()
    |> safe_reason()
  end

  defp message(error) do
    error
    |> field(:response_body)
    |> body_message()
    |> case do
      nil -> reason_message(error)
      message -> safe_reason(message)
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

  defp safe_transport_reason?(reason) do
    reason = field(reason, :reason) || field(reason, :original) || reason

    reason in @safe_transport_reasons or
      (is_binary(reason) and
         String.contains?(String.downcase(reason), [
           "connection refused",
           "econnrefused",
           "nxdomain",
           "enotfound",
           "unreachable",
           "certificate"
         ]))
  end

  defp code(%RequestError{code: code}), do: code
  defp code(%ReqLLM.Error.API.Timeout{kind: kind}), do: "upstream_#{kind}_timeout"

  defp code({:websocket_error_event, event}) when is_map(event),
    do: event |> provider_event_body() |> body_code()

  defp code(error) do
    field(error, :provider_code) ||
      error |> field(:response_body) |> body_code()
  end

  defp status(%RequestError{}), do: 400
  defp status(%ReqLLM.Error.API.Timeout{}), do: 504

  defp status(%WebSockex.RequestError{code: status})
       when is_integer(status) and status >= 400 and status <= 599,
       do: status

  defp status({:websocket_error_event, event}) when is_map(event),
    do: event |> provider_event_body() |> body_status()

  defp status(error) do
    case field(error, :status) || field(error, :status_code) do
      status when is_integer(status) and status >= 400 and status <= 599 -> status
      _other -> nil
    end
  end

  defp provider_event_body(%{"error" => error}) when is_map(error), do: error
  defp provider_event_body(%{error: error}) when is_map(error), do: error
  defp provider_event_body(event), do: event

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

  defp body_status(%{"status" => status}) when is_integer(status), do: valid_status(status)
  defp body_status(%{status: status}) when is_integer(status), do: valid_status(status)
  defp body_status(%{"error" => error}) when is_map(error), do: body_status(error)
  defp body_status(%{error: error}) when is_map(error), do: body_status(error)
  defp body_status(_body), do: nil

  defp valid_status(status) when status >= 400 and status <= 599, do: status
  defp valid_status(_status), do: nil

  defp safe_reason(reason) when is_binary(reason) do
    reason = String.trim(reason)
    downcased = String.downcase(reason)

    unsafe? =
      reason == "" or
        String.contains?(reason, [
          "{:",
          "%{",
          "=>",
          "#PID<",
          "#Port<",
          "#Reference<",
          "#Function<",
          "%ReqLLM.",
          "#Splode"
        ]) or
        String.contains?(downcased, [
          "authorization:",
          "authorization=",
          "bearer ",
          "set-cookie",
          "cookie:",
          "headers:",
          "request_body",
          "request body:",
          "tool_arguments",
          "tool arguments:",
          "query:"
        ])

    if unsafe?, do: nil, else: String.slice(reason, 0, @max_message_length)
  end

  defp safe_reason(_reason), do: nil

  defp safe_code(code, fallback)
       when is_binary(code) and byte_size(code) <= 128 do
    if Regex.match?(~r/\A[a-zA-Z0-9_.-]+\z/, code), do: code, else: fallback
  end

  defp safe_code(_code, fallback), do: fallback

  defp status_code(401), do: "authentication_error"
  defp status_code(403), do: "permission_error"
  defp status_code(429), do: "rate_limit_error"
  defp status_code(status) when is_integer(status) and status >= 500, do: "upstream_error"
  defp status_code(_status), do: "api_error"

  defp field(%{} = value, key), do: Map.get(value, key) || Map.get(value, Atom.to_string(key))
  defp field(_value, _key), do: nil
end
