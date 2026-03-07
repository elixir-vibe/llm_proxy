defmodule LLMProxy.Integration.ExaTest do
  use ExUnit.Case

  import Plug.Conn
  import Plug.Test

  alias Ecto.Adapters.SQL.Sandbox
  alias LLMProxy.Repo
  alias LLMProxy.Router

  @moduletag :integration
  @moduletag timeout: 30_000

  @api_key Application.compile_env(:llm_proxy, :exa_api_key, "")

  if @api_key == "" or is_nil(@api_key) do
    @moduletag :skip
  end

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "search" do
    test "POST /v1/exa/search returns results" do
      master_key = Application.get_env(:llm_proxy, :master_key)

      body =
        Jason.encode!(%{
          "query" => "latest Elixir programming news",
          "num_results" => 3
        })

      conn =
        conn(:post, "/v1/exa/search", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{master_key}")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert is_list(response["results"])
    end
  end
end
