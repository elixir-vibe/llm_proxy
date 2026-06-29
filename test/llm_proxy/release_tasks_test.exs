defmodule LLMProxy.ReleaseTasksTest do
  use ExUnit.Case, async: false

  alias LLMProxy.ReleaseTasks

  test "Codex login release task starts Req Finch before token exchange" do
    Application.stop(:req)
    Application.stop(:finch)

    assert :ok = ReleaseTasks.ensure_http_client_started()
    assert Process.whereis(Req.Finch)
  after
    ReleaseTasks.ensure_http_client_started()
  end
end
