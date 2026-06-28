defmodule LLMProxy.HTTPTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias LLMProxy.HTTP

  test "send_json/3 writes JSON responses" do
    conn = HTTP.send_json(conn(:get, "/"), 201, %{ok: true})

    assert conn.status == 201
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    assert Jason.decode!(conn.resp_body) == %{"ok" => true}
  end
end
