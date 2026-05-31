defmodule LLMProxy.HTTP.Routes.FeedbackTest do
  use ExUnit.Case

  alias LLMProxy.HTTP.Routes.Feedback
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  setup do
    TestSupport.checkout_repo()
    :ok
  end

  test "records feedback by request id and links matching trace" do
    {:ok, key, raw_key} = Storage.create_key("feedback-user")

    {:ok, trace} =
      Storage.record_trace(%{
        key_id: key.id,
        model: "gpt-4o",
        request_body: Jason.encode!(%{"input" => "hi"}),
        response_body: Jason.encode!(%{"output" => "hello"}),
        metadata: %{"trace_id" => "request-123"},
        timestamp: DateTime.utc_now()
      })

    conn =
      TestSupport.json_conn(:post, "/", %{
        "request_id" => "request-123",
        "rating" => "positive",
        "comment" => "good answer"
      })
      |> TestSupport.put_bearer(raw_key)
      |> Feedback.call(Feedback.init([]))

    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert body["request_id"] == "request-123"
    assert body["trace_id"] == trace.id
    assert body["rating"] == "positive"

    [feedback] = Storage.get_trace_feedback(trace.id)
    assert feedback.comment == "good answer"
  end

  test "validates feedback input" do
    {:ok, _key, raw_key} = Storage.create_key("feedback-invalid")

    conn =
      TestSupport.json_conn(:post, "/", %{"rating" => "great"})
      |> TestSupport.put_bearer(raw_key)
      |> Feedback.call(Feedback.init([]))

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "request_id or trace_id is required"
  end
end
