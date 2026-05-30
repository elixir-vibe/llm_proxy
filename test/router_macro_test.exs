defmodule LLMProxy.RouterMacroTest do
  use ExUnit.Case

  alias LLMProxy.Providers.Registry
  alias LLMProxy.TestSupport

  defmodule MacroProvider do
    def name, do: "macro-provider"
    def models, do: ["macro-model"]
  end

  defmodule CoreOnlyRouter do
    use Phoenix.Router
    use LLMProxy.Router

    llm_proxy("/llm", admin: false)
  end

  defmodule SetupRouter do
    use Phoenix.Router
    use LLMProxy.Router, mount: "/proxy", admin: false, setup: true
  end

  setup do
    TestSupport.checkout_repo()
    Registry.register(MacroProvider)
    :ok
  end

  test "llm_proxy/2 mounts core routes without admin routes" do
    models_conn = Plug.Test.conn(:get, "/llm/v1/models") |> CoreOnlyRouter.call([])

    assert models_conn.status == 200
    assert Enum.any?(Jason.decode!(models_conn.resp_body)["data"], &(&1["id"] == "macro-model"))

    assert_raise Phoenix.Router.NoRouteError, fn ->
      Plug.Test.conn(:get, "/llm/keys") |> CoreOnlyRouter.call([])
    end
  end

  test "use LLMProxy.Router can mount configured route groups" do
    setup_conn = Plug.Test.conn(:get, "/proxy/setup/models") |> SetupRouter.call([])

    assert setup_conn.status == 200
    assert Enum.any?(Jason.decode!(setup_conn.resp_body), &(&1["id"] == "macro-model"))

    assert_raise Phoenix.Router.NoRouteError, fn ->
      Plug.Test.conn(:get, "/proxy/keys") |> SetupRouter.call([])
    end
  end
end
