if Code.ensure_loaded?(Incant) do
  defmodule LLMProxy.Admin.ProviderUsagePollTest.Layouts do
    use Phoenix.Component

    def root(assigns) do
      ~H"""
      <html><body>{@inner_content}</body></html>
      """
    end
  end

  defmodule LLMProxy.Admin.ProviderUsagePollTest.Router do
    use Phoenix.Router
    import Phoenix.LiveView.Router
    use LLMProxy.Admin.Router

    pipeline :browser do
      plug(:accepts, ["html"])
      plug(:fetch_session)
      plug(:fetch_live_flash)
      plug(:put_root_layout, {LLMProxy.Admin.ProviderUsagePollTest.Layouts, :root})
      plug(:protect_from_forgery)
      plug(:put_secure_browser_headers)
    end

    scope "/" do
      pipe_through(:browser)
      llm_proxy_incant("/admin", LLMProxy.Admin)
    end
  end

  defmodule LLMProxy.Admin.ProviderUsagePollTest.Endpoint do
    use Phoenix.Endpoint, otp_app: :llm_proxy

    @session_options [store: :cookie, key: "_poll_test", signing_salt: "poll-test"]

    socket("/live", Phoenix.LiveView.Socket,
      websocket: [connect_info: [session: @session_options]]
    )

    plug(Plug.Session, @session_options)
    plug(LLMProxy.Admin.ProviderUsagePollTest.Router)
  end

  defmodule LLMProxy.Admin.ProviderUsagePollTest do
    use ExUnit.Case, async: false

    import Phoenix.ConnTest
    import Phoenix.LiveViewTest

    @moduletag :incant
    @endpoint LLMProxy.Admin.ProviderUsagePollTest.Endpoint

    alias LLMProxy.Admin.ProviderUsagePoll
    alias LLMProxy.ProviderUsage.{Server, Snapshot, Window}

    setup do
      saved = Application.fetch_env(:llm_proxy, :admin_provider_usage_poll_interval_ms)

      on_exit(fn ->
        case saved do
          {:ok, value} ->
            Application.put_env(:llm_proxy, :admin_provider_usage_poll_interval_ms, value)

          :error ->
            Application.delete_env(:llm_proxy, :admin_provider_usage_poll_interval_ms)
        end
      end)

      :ok
    end

    test "reloads an open provider usage dashboard after a poll message" do
      server_state = :sys.get_state(Server)

      on_exit(fn ->
        :sys.replace_state(Server, fn _state -> server_state end)
        Application.delete_env(:llm_proxy, @endpoint)
      end)

      Application.put_env(:llm_proxy, @endpoint,
        secret_key_base: String.duplicate("0", 64),
        live_view: [signing_salt: "poll-test-live"],
        pubsub_server: LLMProxy.Admin.ProviderUsagePollTest.PubSub,
        server: false
      )

      start_supervised!({Phoenix.PubSub, name: LLMProxy.Admin.ProviderUsagePollTest.PubSub})
      start_supervised!(@endpoint)

      put_snapshot(25)

      assert {:ok, view, html} = live(build_conn(), "/admin/dashboards/provider_usage")
      assert html =~ "75.0%"

      put_snapshot(80)
      %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
      send(view.pid, {:llm_proxy_provider_usage_poll, assigns.llm_proxy_usage_poll_token})

      assert_patch(view, "/admin/dashboards/provider_usage")
      assert render(view) =~ "20.0%"
    end

    test "does not schedule polling outside the provider usage dashboard" do
      on_exit(fn -> Application.delete_env(:llm_proxy, @endpoint) end)

      Application.put_env(:llm_proxy, @endpoint,
        secret_key_base: String.duplicate("0", 64),
        live_view: [signing_salt: "poll-test-live"],
        pubsub_server: LLMProxy.Admin.ProviderUsagePollTest.OtherPubSub,
        server: false
      )

      start_supervised!({Phoenix.PubSub, name: LLMProxy.Admin.ProviderUsagePollTest.OtherPubSub})
      start_supervised!(@endpoint)

      assert {:ok, view, _html} = live(build_conn(), "/admin/resources")
      %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)

      assert assigns.llm_proxy_usage_poll_timer == nil
      assert assigns.llm_proxy_usage_poll_token == nil
    end

    test "cancels the dashboard timer after live navigation" do
      on_exit(fn -> Application.delete_env(:llm_proxy, @endpoint) end)

      Application.put_env(:llm_proxy, @endpoint,
        secret_key_base: String.duplicate("0", 64),
        live_view: [signing_salt: "poll-test-live"],
        pubsub_server: LLMProxy.Admin.ProviderUsagePollTest.NavigationPubSub,
        server: false
      )

      start_supervised!(
        {Phoenix.PubSub, name: LLMProxy.Admin.ProviderUsagePollTest.NavigationPubSub}
      )

      start_supervised!(@endpoint)

      assert {:ok, view, _html} = live(build_conn(), "/admin/dashboards/provider_usage")
      %{socket: %{assigns: dashboard_assigns}} = :sys.get_state(view.pid)
      assert is_reference(dashboard_assigns.llm_proxy_usage_poll_timer)
      assert is_reference(dashboard_assigns.llm_proxy_usage_poll_token)

      render_patch(view, "/admin/resources")
      %{socket: %{assigns: resource_assigns}} = :sys.get_state(view.pid)

      assert resource_assigns.llm_proxy_usage_poll_timer == nil
      assert resource_assigns.llm_proxy_usage_poll_token == nil

      send(
        view.pid,
        {:llm_proxy_provider_usage_poll, dashboard_assigns.llm_proxy_usage_poll_token}
      )

      assert render(view) =~ "Provider Tokens"
      assert Process.alive?(view.pid)
    end

    test "polls only the provider usage dashboard" do
      assert ProviderUsagePoll.provider_usage_dashboard?(%{"dashboard" => "provider_usage"})
      refute ProviderUsagePoll.provider_usage_dashboard?(%{"dashboard" => "operations"})
      refute ProviderUsagePoll.provider_usage_dashboard?(%{})
    end

    test "uses a bounded one-minute default" do
      Application.delete_env(:llm_proxy, :admin_provider_usage_poll_interval_ms)
      assert ProviderUsagePoll.interval_ms() == 60_000

      Application.put_env(:llm_proxy, :admin_provider_usage_poll_interval_ms, 15_000)
      assert ProviderUsagePoll.interval_ms() == 15_000

      for invalid <- [0, 14_999, 3_600_001, "60000"] do
        Application.put_env(:llm_proxy, :admin_provider_usage_poll_interval_ms, invalid)

        assert_raise ArgumentError, fn ->
          ProviderUsagePoll.interval_ms()
        end
      end
    end

    defp put_snapshot(used_percent) do
      now = DateTime.utc_now()

      snapshot = %Snapshot{
        token_id: 101,
        provider_label: "OpenAI Codex",
        account_label: "Account #101",
        availability: :available,
        state: :fresh,
        refreshed_at: now,
        attempted_at: now,
        windows: [
          %Window{
            label: "Weekly",
            used_percent: used_percent,
            remaining_percent: 100 - used_percent,
            resets_at: DateTime.add(now, 3_600, :second)
          }
        ]
      }

      :sys.replace_state(Server, fn state -> %{state | snapshots: %{101 => snapshot}} end)
    end
  end
end
