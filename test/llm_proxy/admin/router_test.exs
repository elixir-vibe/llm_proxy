if Code.ensure_loaded?(Incant) do
  defmodule LLMProxy.Admin.RouterTest do
    use ExUnit.Case, async: true

    @moduletag :incant

    alias LLMProxy.Admin.ProviderUsagePoll

    defmodule LocalRouter do
      use Phoenix.Router
      import Phoenix.LiveView.Router
      use LLMProxy.Admin.Router

      scope "/" do
        llm_proxy_incant("/admin", LLMProxy.Admin)
      end
    end

    defmodule RegistryRouter do
      use Phoenix.Router
      import Phoenix.LiveView.Router
      use LLMProxy.Admin.Router

      scope "/" do
        llm_proxy_incant("", [registry: Incant.Service.RegistryServer], base_path: "/")
      end
    end

    test "mounts local Incant routes" do
      assert %{
               plug: Phoenix.LiveView.Plug,
               plug_opts: :dashboard,
               phoenix_live_view: {Incant.Live.Admin, :dashboard, _opts, live_session}
             } =
               Phoenix.Router.route_info(
                 LocalRouter,
                 "GET",
                 "/admin/dashboards/provider_usage",
                 "localhost"
               )

      assert %{extra: %{on_mount: [%{id: {ProviderUsagePoll, :default}}]}} = live_session
    end

    test "mounts service registry routes" do
      assert %{
               plug: Phoenix.LiveView.Plug,
               plug_opts: :dashboard,
               phoenix_live_view: {Incant.Live.Admin, :dashboard, _opts, live_session}
             } =
               Phoenix.Router.route_info(
                 RegistryRouter,
                 "GET",
                 "/llm_proxy/dashboards/provider_usage",
                 "localhost"
               )

      assert %{extra: %{on_mount: [%{id: {ProviderUsagePoll, :default}}]}} = live_session
    end
  end
end
