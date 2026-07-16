defmodule LLMProxy.HTTP do
  @moduledoc """
  Req client factory that applies LLMProxy's HTTP instrumentation and test plug configuration.
  """

  import Plug.Conn

  def request_meta(conn, request_id, route) do
    %{method: conn.method, path: conn.request_path, request_id: request_id, route: route}
  end

  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  def new(opts) do
    opts
    |> maybe_put_test_plug()
    |> Req.new()
    |> OpentelemetryReq.attach()
  end

  defp maybe_put_test_plug(opts) do
    case Application.get_env(:llm_proxy, :req_plug) do
      nil -> opts
      plug -> Keyword.put_new(opts, :plug, plug)
    end
  end
end
