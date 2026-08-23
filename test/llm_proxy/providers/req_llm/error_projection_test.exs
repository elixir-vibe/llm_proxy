defmodule LLMProxy.Providers.ReqLLM.ErrorProjectionTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Providers.ReqLLM.{ErrorProjection, Projection}
  alias LLMProxy.Providers.Result
  alias LLMProxy.Stream.Event
  alias ReqLLM.Error.API.Request, as: APIRequestError
  alias ReqLLM.Error.API.Stream, as: APIStreamError
  alias ReqLLM.Error.API.Timeout, as: APITimeout
  alias ReqLLM.StreamEvent

  test "projects nested stream errors without exposing Elixir terms or upstream headers" do
    request_error =
      APIRequestError.exception(
        reason: "quota exhausted",
        status: 403,
        response_body: %{
          "message" => "Quota exhausted. Upgrade your plan.",
          "type" => "access_terminated_error"
        },
        headers: [
          {"set-cookie", "secret-cookie"},
          {"x-trace-id", "upstream-trace"}
        ],
        provider_code: "access_terminated_error",
        retryable: false
      )

    stream_error =
      APIStreamError.exception(
        reason: "Stream failed: #{inspect(request_error)}",
        cause: request_error
      )

    assert ErrorProjection.project(stream_error) == %{
             message: "Quota exhausted. Upgrade your plan.",
             code: "access_terminated_error",
             status: 403
           }

    assert [
             %Event{
               data: %{
                 "error" => %{
                   "message" => "Quota exhausted. Upgrade your plan.",
                   "type" => "access_terminated_error",
                   "code" => "access_terminated_error",
                   "status" => 403
                 }
               }
             }
           ] = Projection.events(StreamEvent.new(:error, stream_error), "k3")

    result = Result.stream_failure(LLMProxy.Providers.ReqLLM, "gpt-5.6-sol", nil, stream_error)
    assert result.status == 403
    assert result.error == "Quota exhausted. Upgrade your plan."
    assert Result.client_error(result)["code"] == "access_terminated_error"

    rendered = inspect(ErrorProjection.client_error(stream_error))
    refute rendered =~ "ReqLLM.Error"
    refute rendered =~ "secret-cookie"
    refute rendered =~ "upstream-trace"
    refute rendered =~ "set-cookie"
  end

  test "projects safe fields from WebSocket provider error events" do
    event =
      {:websocket_error_event,
       %{
         "type" => "error",
         "error" => %{
           "message" => "Our servers are currently overloaded. Please try again later.",
           "code" => "server_overloaded",
           "status" => 503,
           "request_body" => "private request"
         }
       }}

    stream_error =
      APIStreamError.exception(
        reason: "Stream failed with a provider event",
        cause: event
      )

    assert ErrorProjection.client_error(stream_error) == %{
             "message" => "Our servers are currently overloaded. Please try again later.",
             "type" => "server_overloaded",
             "code" => "server_overloaded",
             "status" => 503
           }

    refute Jason.encode!(ErrorProjection.client_error(stream_error)) =~ "private request"
  end

  test "rejects unsafe WebSocket provider error fields" do
    event =
      {:websocket_error_event,
       %{
         "error" => %{
           "message" => "authorization=Bearer secret",
           "code" => "bad {:code",
           "status" => 200
         }
       }}

    client_error = ErrorProjection.client_error(event)

    assert client_error == %{
             "message" => "Upstream provider request failed",
             "type" => "upstream_error",
             "code" => "upstream_error",
             "status" => 502
           }

    refute Jason.encode!(client_error) =~ "secret"
  end

  test "rejects unsafe provider message and code fields" do
    error =
      APIRequestError.exception(
        reason: "failed",
        status: 502,
        response_body: %{
          "message" => "headers: authorization=Bearer secret",
          "code" => "bad {:code"
        },
        provider_code: "bad {:code",
        retryable: false
      )

    rendered = Jason.encode!(ErrorProjection.client_error(error))

    refute rendered =~ "secret"
    refute rendered =~ "headers"
    refute rendered =~ "{:"
    assert ErrorProjection.client_error(error)["code"] == "upstream_error"
  end

  test "classifies local storage failures without exposing database details" do
    error =
      QuackDB.Error.new(:transaction_conflict, "Conflict on usage_log",
        source: :server,
        retriable?: true,
        query: "INSERT secret-token"
      )

    assert ErrorProjection.client_error(error) == %{
             "message" => "Internal stream processing failed",
             "type" => "internal_error",
             "code" => "internal_error",
             "status" => 500
           }

    refute inspect(ErrorProjection.client_error(error)) =~ "secret-token"
  end

  test "falls back to a stable generic error instead of inspecting unknown terms" do
    assert ErrorProjection.client_error({:unexpected, self()}) == %{
             "message" => "Upstream provider request failed",
             "type" => "upstream_error",
             "code" => "upstream_error",
             "status" => 502
           }
  end

  test "projects typed timeout phases without collapsing diagnostics" do
    for {kind, timeout, message} <- [
          {:connect, 10_000, "Provider connection exceeded the timeout of 10000ms"},
          {:receive, 30_000, "Provider transport received no data for 30000ms"},
          {:total, 60_000, "Model call exceeded the total timeout of 60000ms"},
          {:stream_idle, 45_000, "Model stream made no semantic progress for 45000ms"}
        ] do
      error = APITimeout.exception(kind: kind, timeout: timeout)

      assert ErrorProjection.client_error(error) == %{
               "message" => message,
               "type" => "upstream_#{kind}_timeout",
               "code" => "upstream_#{kind}_timeout",
               "status" => 504
             }
    end
  end

  test "classifies replay safety from dispatch evidence" do
    assert ErrorProjection.replay_safety(APITimeout.exception(kind: :connect, timeout: 10_000)) ==
             :safe

    assert ErrorProjection.replay_safety(APITimeout.exception(kind: :receive, timeout: 30_000)) ==
             :uncertain

    assert ErrorProjection.replay_safety(%Req.TransportError{reason: :econnrefused}) == :safe
    assert ErrorProjection.replay_safety(%Req.TransportError{reason: :econnreset}) == :uncertain

    assert ErrorProjection.replay_safety(
             APIRequestError.exception(reason: "denied", status: 401, retryable: false)
           ) == :forbidden
  end

  test "projects bounded WebSocket handshake failures" do
    error = WebSockex.RequestError.exception(code: 503, message: "Service Unavailable")

    assert ErrorProjection.client_error(error) == %{
             "message" => "WebSocket handshake failed: Service Unavailable",
             "type" => "upstream_error",
             "code" => "upstream_error",
             "status" => 503
           }

    unsafe =
      WebSockex.RequestError.exception(code: 401, message: "authorization=Bearer secret")

    refute Jason.encode!(ErrorProjection.client_error(unsafe)) =~ "secret"
  end

  test "surfaces the transport reason for connection-level failures" do
    for reason <- [:econnrefused, :nxdomain, :closed, :timeout] do
      error = %Req.TransportError{reason: reason}

      projected = ErrorProjection.project(error)

      assert projected.message == "Connection error: #{reason}"
      assert projected.status == 502
    end
  end

  test "surfaces a safe runtime error message" do
    error = RuntimeError.exception("WebSocket closed 1000")

    assert ErrorProjection.project(error).message == "WebSocket closed 1000"
  end

  test "surfaces a WebSocket close code without exposing close details" do
    error = ErlangError.exception(original: {:remote, 1000, "private upstream detail"})

    assert ErrorProjection.project(error).message == "WebSocket closed 1000"
    refute ErrorProjection.project(error).message =~ "private"
  end

  test "projects a structured stream cause instead of its inspected wrapper" do
    error =
      APIStreamError.exception(
        reason: ~s(Stream failed: {:remote, 1000, ""}),
        cause: {:remote, 1000, ""}
      )

    client_error = ErrorProjection.client_error(error)

    assert client_error["message"] == "WebSocket closed 1000"
    refute Jason.encode!(client_error) =~ "{:remote"
    refute Jason.encode!(client_error) =~ "Stream failed:"
  end

  test "surfaces nested transport reasons through the cause chain" do
    transport = %Req.TransportError{reason: :econnrefused}

    stream_error =
      APIStreamError.exception(
        reason: "stream terminated",
        cause: transport
      )

    assert ErrorProjection.project(stream_error).message == "Connection error: econnrefused"
  end

  test "string transport reasons are recognized" do
    error = %{reason: "econnrefused"}
    assert ErrorProjection.project(error).message == "Connection error: econnrefused"
  end
end
