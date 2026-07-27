defmodule LLMProxy.HTTP.ErrorResponse do
  @moduledoc """
  Renders sanitized public error envelopes for supported HTTP protocols.

  Internal terms and exception details must be projected before this boundary.
  This module accepts only stable message/code fields and chooses the native
  Anthropic Messages envelope when the request path targets that API.
  """

  alias LLMProxy.HTTP

  @max_message_length 2_000

  @type error_map :: %{String.t() => term()}

  @spec send(Plug.Conn.t(), pos_integer(), String.t(), term()) :: Plug.Conn.t()
  def send(conn, status, code, message) do
    case protocol(conn) do
      :anthropic -> send_anthropic(conn, status, code, message)
      :openai -> send_openai(conn, status, code, message)
    end
  end

  @spec send_openai(Plug.Conn.t(), pos_integer(), String.t(), term()) :: Plug.Conn.t()
  def send_openai(conn, status, code, message) do
    HTTP.send_json(conn, status, %{"error" => openai_error(status, code, message)})
  end

  @spec send_openai(Plug.Conn.t(), pos_integer(), map()) :: Plug.Conn.t()
  def send_openai(conn, status, error) when is_map(error) do
    HTTP.send_json(conn, status, %{"error" => openai_error(status, error)})
  end

  @spec send_anthropic(Plug.Conn.t(), pos_integer(), String.t(), term()) :: Plug.Conn.t()
  def send_anthropic(conn, status, type, message) do
    HTTP.send_json(conn, status, %{
      "type" => "error",
      "error" => %{
        "type" => normalize_code(type, status),
        "message" => safe_message(message, fallback_message(status))
      }
    })
  end

  @spec openai_error(pos_integer(), map()) :: error_map()
  def openai_error(status, error) when is_map(error), do: normalize_openai(error, status)

  @spec openai_error(pos_integer(), String.t(), term()) :: error_map()
  def openai_error(status, code, message) do
    code = normalize_code(code, status)

    %{
      "message" => safe_message(message, fallback_message(status)),
      "type" => code,
      "code" => code,
      "status" => status
    }
  end

  @spec safe_message(term(), String.t()) :: String.t()
  def safe_message(message, fallback) when is_binary(message) and is_binary(fallback) do
    message = String.trim(message)

    if message == "" or inspected_term?(message) or sensitive_detail?(message) do
      fallback
    else
      String.slice(message, 0, @max_message_length)
    end
  end

  def safe_message(_message, fallback) when is_binary(fallback), do: fallback

  defp normalize_openai(error, status) do
    message = field(error, "message")
    code = field(error, "code") || field(error, "type") || status_code(status)
    type = field(error, "type") || code

    %{
      "message" => safe_message(message, fallback_message(status)),
      "type" => normalize_code(type, status),
      "code" => normalize_code(code, status),
      "status" => status
    }
    |> maybe_put_param(field(error, "param"))
  end

  defp maybe_put_param(error, param) when is_binary(param) and byte_size(param) <= 256 do
    if Regex.match?(~r/\A[a-zA-Z0-9_.\[\]-]+\z/, param),
      do: Map.put(error, "param", param),
      else: error
  end

  defp maybe_put_param(error, _param), do: error

  defp field(map, "message"), do: Map.get(map, "message") || Map.get(map, :message)
  defp field(map, "code"), do: Map.get(map, "code") || Map.get(map, :code)
  defp field(map, "type"), do: Map.get(map, "type") || Map.get(map, :type)
  defp field(map, "param"), do: Map.get(map, "param") || Map.get(map, :param)

  defp normalize_code(code, status) when is_binary(code) and byte_size(code) <= 128 do
    if Regex.match?(~r/\A[a-zA-Z0-9_.-]+\z/, code), do: code, else: status_code(status)
  end

  defp normalize_code(_code, status), do: status_code(status)

  defp status_code(400), do: "invalid_request_error"
  defp status_code(401), do: "authentication_error"
  defp status_code(403), do: "permission_error"
  defp status_code(404), do: "not_found_error"
  defp status_code(413), do: "request_too_large"
  defp status_code(429), do: "rate_limit_error"
  defp status_code(503), do: "service_unavailable"
  defp status_code(status) when status >= 500, do: "upstream_error"
  defp status_code(_status), do: "api_error"

  defp fallback_message(400), do: "Invalid request"
  defp fallback_message(401), do: "Authentication failed"
  defp fallback_message(403), do: "Permission denied"
  defp fallback_message(404), do: "Not found"
  defp fallback_message(413), do: "Request body is too large"
  defp fallback_message(429), do: "Rate limit exceeded"
  defp fallback_message(503), do: "Service unavailable"
  defp fallback_message(status) when status >= 500, do: "Upstream provider request failed"
  defp fallback_message(_status), do: "Request failed"

  defp protocol(%Plug.Conn{request_path: path}) do
    if String.starts_with?(path, "/v1/messages"), do: :anthropic, else: :openai
  end

  defp sensitive_detail?(message) do
    message
    |> String.downcase()
    |> String.contains?([
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
  end

  defp inspected_term?(message) do
    String.contains?(message, [
      "{:",
      "%{",
      "=>",
      "#PID<",
      "#Port<",
      "#Reference<",
      "#Function<",
      "%ReqLLM.",
      "#Splode"
    ])
  end
end
