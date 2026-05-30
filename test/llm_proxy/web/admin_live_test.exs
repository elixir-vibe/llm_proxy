defmodule LLMProxy.Web.AdminLiveTest do
  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias LLMProxy.Providers.Registry
  alias LLMProxy.Storage
  alias LLMProxy.TestSupport

  @endpoint LLMProxy.Web.Endpoint

  defmodule ModelsProvider do
    def name, do: "admin-live"
    def models, do: ["admin-live-model"]
  end

  setup do
    TestSupport.checkout_repo()
    TestSupport.clear_provider_tokens()
    Registry.register(ModelsProvider)
    Application.put_env(:llm_proxy, :master_key, "admin-secret")

    on_exit(fn ->
      Application.delete_env(:llm_proxy, :master_key)
    end)

    :ok
  end

  test "redirects unauthenticated admin visits to login" do
    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(build_conn(), "/admin")
  end

  test "dashboard shows aggregate stats" do
    {:ok, key, _} = Storage.create_key("dashboard-user")

    Storage.record_usage(%{
      key_id: key.id,
      model: "gpt-4o",
      input_tokens: 1200,
      output_tokens: 400,
      cost_usd: 1.25,
      duration_ms: 250,
      ttft_ms: 40,
      timestamp: DateTime.utc_now()
    })

    Storage.record_service_usage(%{
      key_id: key.id,
      service: "exa",
      endpoint: "/search",
      timestamp: DateTime.utc_now()
    })

    {:ok, _view, html} = live(admin_conn(), "/admin")

    assert html =~ "Dashboard"
    assert html =~ "API Keys"
    assert html =~ "gpt-4o"
    assert html =~ "exa"
  end

  test "keys live creates and deletes keys" do
    {:ok, view, html} = live(admin_conn(), "/admin/keys")

    assert html =~ "API Keys"

    assert render_submit(form(view, "form[phx-submit=create_key]", %{"name" => "created-key"})) =~
             "created-key"

    assert render(view) =~ "copy it now"

    [key] = Storage.list_keys()

    assert view
           |> element("button[phx-click=delete_key][phx-value-id='#{key.id}']")
           |> render_click() =~ "No API keys"
  end

  test "tokens live manages tokens" do
    {:ok, token} = Storage.add_token("openai", "api-key", "token-123456789012")
    {:ok, view, html} = live(admin_conn(), "/admin/tokens")

    assert html =~ "Token Pool"
    assert html =~ "token-"

    render_submit(
      form(view, "form[phx-submit=add_token]", %{
        "provider" => "anthropic",
        "kind" => "api-key",
        "token" => "new-token-1234567890",
        "proxy" => "http://proxy"
      })
    )

    assert render(view) =~ "anthropic"

    view
    |> element("button[phx-click=toggle_enabled][phx-value-id='#{token.id}']")
    |> render_click()

    assert render(view) =~ "OFF"

    view
    |> element("button[phx-click=delete_token][phx-value-id='#{token.id}']")
    |> render_click()

    assert render_click(element(view, "button[phx-click=clear_rate_limits]")) =~ "Token Pool"
  end

  test "messages live filters stored messages" do
    {:ok, key, _} = Storage.create_key("messages-user")

    Storage.log_message(%{
      key_id: key.id,
      model: "gpt-4o",
      route: "chat",
      user_message: "hello admin",
      timestamp: DateTime.utc_now()
    })

    {:ok, view, html} = live(admin_conn(), "/admin/messages")

    assert html =~ "Message Log"
    assert html =~ "hello admin"

    render_change(element(view, "form[phx-change=search]"), %{"q" => "hello"})
    assert_patch(view, "/admin/messages?dir=desc&q=hello&sort=timestamp")
    assert render(view) =~ "hello admin"
  end

  test "traces live shows trace details" do
    {:ok, key, _} = Storage.create_key("trace-user")

    {:ok, trace} =
      Storage.record_trace(%{
        key_id: key.id,
        model: "gpt-4o",
        provider: "openai",
        request_body: ~s({"input":"hello"}),
        response_body: ~s({"output":"world"}),
        input_tokens: 10,
        output_tokens: 5,
        cost_usd: 0.25,
        duration_ms: 123,
        ttft_ms: 45,
        session_id: "session-1",
        timestamp: DateTime.utc_now()
      })

    {:ok, view, html} = live(admin_conn(), "/admin/traces")

    assert html =~ "Traces"
    assert html =~ "session-1"

    view
    |> element("button[phx-click=view_trace][phx-value-id='#{trace.id}']")
    |> render_click()

    assert render(view) =~ "Request"
    assert render(view) =~ "world"
    assert render_click(element(view, "button[phx-click=close_trace]")) =~ "Traces"
  end

  test "models live lists registered provider models" do
    {:ok, _view, html} = live(admin_conn(), "/admin/models")

    assert html =~ "Models"
    assert html =~ "admin-live"
    assert html =~ "admin-live-model"
  end

  defp admin_conn do
    build_conn()
    |> init_test_session(admin_authenticated: true)
  end
end
