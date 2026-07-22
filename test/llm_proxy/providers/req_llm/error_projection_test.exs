defmodule LLMProxy.Providers.ReqLLM.ErrorProjectionTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Providers.ReqLLM.{ErrorProjection, Projection}
  alias LLMProxy.Stream.Event
  alias ReqLLM.Error.API.Request, as: APIRequestError
  alias ReqLLM.Error.API.Stream, as: APIStreamError

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
        ]
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
           ] = Projection.events(%{type: :error, data: stream_error}, "k3")

    rendered = inspect(ErrorProjection.client_error(stream_error))
    refute rendered =~ "ReqLLM.Error"
    refute rendered =~ "secret-cookie"
    refute rendered =~ "upstream-trace"
    refute rendered =~ "set-cookie"
  end

  test "falls back to a stable generic error instead of inspecting unknown terms" do
    assert ErrorProjection.client_error({:unexpected, self()}) == %{
             "message" => "Upstream provider request failed",
             "type" => "upstream_error",
             "code" => "upstream_error",
             "status" => 502
           }
  end

  test "surfaces the transport reason for connection-level failures" do
    for reason <- [:econnrefused, :nxdomain, :closed, :timeout] do
      error = %Req.TransportError{reason: reason}

      projected = ErrorProjection.project(error)

      assert projected.message == "Connection error: #{reason}"
      assert projected.status == 502
    end
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
