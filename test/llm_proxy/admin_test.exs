defmodule LLMProxy.AdminTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Incant.ActionResult
  alias Incant.Live.Rows
  alias Incant.Service.{Page, Registry, Runtime, Session}
  alias LLMProxy.Admin.CodexOAuth
  alias LLMProxy.Providers.OpenAICodex.OAuth
  alias LLMProxy.Storage
  alias LLMProxy.Storage.Repo.SQLite
  alias LLMProxy.TestSupport

  defmodule QueryCaptureRepo do
    def aggregate(%Ecto.Query{}, :count), do: 1

    def all(%Ecto.Query{} = query) do
      send(self(), {:captured_query, query})

      [
        %{
          id: "key-1",
          name: "test",
          total_spend_usd: 0.0,
          input_tokens: 0,
          output_tokens: 0,
          cache_read_tokens: 0,
          trace_requests: false
        }
      ]
    end
  end

  defmodule AdminServer do
    use SafeRPC.Adapter.Server, service: LLMProxy.Admin
  end

  setup do
    TestSupport.checkout_repo()
  end

  test "describes LLMProxy admin as a portable Incant contract" do
    assert %Incant.Admin.Contract{} = contract = Incant.Admin.describe(LLMProxy.Admin)

    assert contract.id == "llm_proxy"
    assert contract.service == :llm_proxy
    assert contract.version == "1"
    assert contract.opts.title == "LLM Proxy"

    resource_ids = Enum.map(contract.resources, & &1.id)
    assert resource_ids == ["api_key", "provider_token", "trace", "message"]

    assert [%{id: "api_key", title: "API Keys"} = api_key | _] = contract.resources

    assert Enum.map(api_key.table.columns, & &1.id) == [
             "name",
             "total_spend_usd",
             "input_tokens",
             "output_tokens",
             "cache_read_tokens",
             "trace_requests"
           ]

    assert Enum.map(api_key.table.columns, & &1.opts[:priority]) == [
             :primary,
             :primary,
             :secondary,
             :secondary,
             :tertiary,
             :secondary
           ]

    assert Enum.map(api_key.table.actions, & &1.id) == ["delete"]
    assert Enum.map(api_key.table.page_actions, & &1.id) == ["create"]

    provider_token = Enum.find(contract.resources, &(&1.id == "provider_token"))
    trace = Enum.find(contract.resources, &(&1.id == "trace"))
    message = Enum.find(contract.resources, &(&1.id == "message"))

    assert Enum.find(trace.table.columns, &(&1.id == "key_id")).opts[:format] == :id
    assert Enum.find(message.table.columns, &(&1.id == "key_id")).opts[:format] == :id

    assert Enum.map(provider_token.table.page_actions, & &1.id) == [
             "codex_oauth_start",
             "codex_oauth_complete"
           ]

    provider_filter = Enum.find(provider_token.table.filters, &(&1.id == "provider"))
    assert provider_filter.type == :select

    assert provider_filter.opts.options == [
             %{label: "Anthropic", value: "anthropic"},
             %{label: "OpenAI", value: "openai"},
             %{label: "OpenAI Codex", value: "openai-codex"},
             %{label: "OpenRouter", value: "openrouter"}
           ]

    model_filter = Enum.find(message.table.filters, &(&1.id == "model"))
    assert model_filter.type == :combobox
    assert model_filter.opts.options_from == :model

    enabled_column = Enum.find(provider_token.table.columns, &(&1.id == "enabled"))
    assert enabled_column.opts.true_label == "Enabled"
    assert enabled_column.opts.false_label == "Disabled"

    refute Map.has_key?(api_key.opts, :schema)

    assert [%{id: "operations", title: "Operations"} = dashboard] = contract.dashboards

    assert Enum.map(dashboard.widgets, & &1.id) == [
             "api_keys",
             "requests",
             "spend",
             "input_tokens",
             "output_tokens",
             "recent_usage",
             "service_usage"
           ]

    assert dashboard.grid == %{columns: 10}
    assert Enum.map(dashboard.widgets, & &1.opts[:span]) == [2, 2, 2, 2, 2, 7, 3]

    recent_usage = Enum.find(dashboard.widgets, &(&1.id == "recent_usage"))

    assert Enum.map(recent_usage.opts.columns, & &1.name) == [
             :timestamp,
             :provider,
             :model,
             :input_tokens,
             :output_tokens,
             :cost_usd,
             :duration_ms,
             :ttft_ms,
             :key_id
           ]

    assert Enum.map(recent_usage.opts.columns, & &1.opts[:label]) == [
             "Timestamp",
             "Provider",
             "Model",
             "Input tokens",
             "Output tokens",
             "Cost",
             "Duration",
             "TTFT",
             "Key"
           ]

    assert recent_usage.opts[:preview_rows] == 10

    assert Enum.map(recent_usage.opts.columns, & &1.opts[:priority]) == [
             :primary,
             :secondary,
             :primary,
             :secondary,
             :tertiary,
             :secondary,
             :tertiary,
             :tertiary,
             :tertiary
           ]

    assert Enum.all?(dashboard.widgets, fn widget -> not Map.has_key?(widget.opts, :query) end)
  end

  test "declarative resource projections compile for the production QuackDB adapter" do
    resource = %{Incant.metadata(LLMProxy.Admin.Resources.ApiKey) | repo: QueryCaptureRepo}

    page =
      Incant.Live.Rows.page(resource, %{
        page: 1,
        page_size: 25,
        sort: "",
        search: "",
        filters: %{}
      })

    assert page.total == 1
    assert_receive {:captured_query, query}

    sql = query |> Ecto.Adapters.QuackDB.Query.all() |> IO.iodata_to_binary()
    assert sql =~ ~s(SELECT q0."id", q0."name")
    refute sql =~ "q0.value"
  end

  test "declares mutually exclusive provider token actions" do
    resource = Incant.metadata(LLMProxy.Admin.Resources.ProviderToken)
    enable = Enum.find(resource.table.actions, &(&1.name == :enable))
    disable = Enum.find(resource.table.actions, &(&1.name == :disable))

    assert enable.opts[:callback] == {LLMProxy.Admin.Resources.ProviderToken, :enable}
    assert enable.opts[:available_if] == [enabled: false]
    assert disable.opts[:callback] == {LLMProxy.Admin.Resources.ProviderToken, :disable}
    assert disable.opts[:available_if] == [enabled: true]
    assert disable.opts[:confirm] == "Disable this provider token?"
  end

  test "returns authoritative message pages through the Incant runtime" do
    {:ok, key, _raw} = Storage.create_key("incant-page")

    for index <- 1..30 do
      Storage.log_message(%{
        key_id: key.id,
        model: "model-#{rem(index, 2)}",
        route: "chat",
        user_message: if(index == 17, do: "unique needle", else: "message #{index}")
      })
    end

    assert {:ok, page} =
             Runtime.index(LLMProxy.Admin, "message", %{
               page: 2,
               page_size: 10,
               sort: "-timestamp",
               search: "",
               filters: %{}
             })

    assert page.page == 2
    assert page.page_size == 10
    assert page.total == 30
    assert page.total_pages == 3
    assert length(page.rows) == 10

    assert page.meta.options["model"] == [
             %{label: "model-0", value: "model-0"},
             %{label: "model-1", value: "model-1"}
           ]

    assert page.meta.options["route"] == [%{label: "chat", value: "chat"}]

    assert {:ok, filtered} =
             Runtime.index(LLMProxy.Admin, "message", %{
               page: 1,
               page_size: 10,
               sort: "model",
               search: "",
               filters: %{"model" => "model-0"}
             })

    assert filtered.total == 15
    assert Enum.all?(filtered.rows, &(Map.get(&1, :model) == "model-0"))

    assert {:ok, searched} =
             Runtime.index(LLMProxy.Admin, "message", %{
               page: 1,
               page_size: 10,
               sort: "",
               search: "needle",
               filters: %{}
             })

    assert Map.get(searched, :error) == nil
    assert searched.total == 1
    assert [%{user_message: "unique needle"}] = searched.rows

    today = Date.to_iso8601(Date.utc_today())

    assert {:ok, dated} =
             Runtime.index(LLMProxy.Admin, "message", %{
               page: 1,
               page_size: 10,
               sort: "",
               search: "",
               filters: %{"timestamp" => %{"from" => today, "to" => today}}
             })

    assert dated.total == 30
  end

  test "transports only applicable provider token actions" do
    {:ok, _enabled} = Storage.add_token("openai", "api-key", "enabled", %{enabled: true})
    {:ok, _disabled} = Storage.add_token("openai", "api-key", "disabled", %{enabled: false})

    assert {:ok, external} =
             Runtime.index_external(LLMProxy.Admin, "provider_token")

    page = Page.from_external(external)
    rows = Map.new(page.rows, &{Rows.field(&1, :enabled), &1.available_actions})

    assert rows[true] == ["disable", "remove"]
    assert rows[false] == ["enable", "remove"]
  end

  test "executes Operations dashboard widgets through Incant service session" do
    socket = socket_path("dashboard-widgets")
    {:ok, server} = AdminServer.start_link(socket: socket)
    Sandbox.allow(SQLite, self(), server)

    {:ok, key, _raw_key} = Storage.create_key("dashboard-widget-user")
    Storage.update_key_usage(key, %{input: 123, output: 45, cost_usd: 0.67})

    assert {:ok, _usage} =
             Storage.record_usage(%{
               key_id: key.id,
               model: "dashboard-model",
               input_tokens: 123,
               output_tokens: 45,
               cost_usd: 0.67,
               provider: "openai",
               timestamp: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    bindings = %{llm_proxy: %{socket: socket, modules: [LLMProxy.Admin]}}

    assert {:ok, %Registry{entries: [entry]}} = Registry.from_bindings(bindings)

    session = Session.new(entry)

    assert {:ok, 1} = Session.run_widget(session, "operations", "api_keys")
    assert {:ok, 1} = Session.run_widget(session, "operations", "requests")
    assert {:ok, 0.67} = Session.run_widget(session, "operations", "spend")
    assert {:ok, 123} = Session.run_widget(session, "operations", "input_tokens")
    assert {:ok, 45} = Session.run_widget(session, "operations", "output_tokens")

    assert {:ok,
            %{
              "columns" => [
                "timestamp",
                "provider",
                "model",
                "input_tokens",
                "output_tokens",
                "cost_usd",
                "duration_ms",
                "ttft_ms",
                "key_id"
              ],
              "rows" => [%{"model" => "dashboard-model"}]
            }} = Session.run_widget(session, "operations", "recent_usage")

    assert {:ok, %{"columns" => ["service", "count"], "rows" => []}} =
             Session.run_widget(session, "operations", "service_usage")

    GenServer.stop(server)
  end

  test "runs API key creation page action" do
    assert {:ok, %ActionResult.Job{id: "api_key:" <> _id, meta: meta}} =
             LLMProxy.Admin.run_action(
               "api_key",
               "create",
               %{assigns: %{"name" => "operator-test", "trace_requests" => true}},
               %{}
             )

    assert %{id: id, name: "operator-test", token: "sk-proxy-" <> _} = meta
    assert key = Storage.find_key(meta.token)
    assert key.id == id
    assert key.trace_requests == true
  end

  test "runs Codex OAuth start page action" do
    assert {:ok, %ActionResult.Job{id: "codex_oauth", meta: %{"oauth" => oauth}}} =
             LLMProxy.Admin.run_action("provider_token", "codex_oauth_start", %{}, %{})

    assert %{
             "authorization_url" => authorization_url,
             "state" => state,
             "verifier" => verifier
           } = oauth

    assert authorization_url =~ "https://auth.openai.com/oauth/authorize"
    assert authorization_url =~ URI.encode_query(%{state: state})
    assert is_binary(verifier)
  end

  test "stores Codex OAuth credentials from live admin process" do
    {:ok, credentials} =
      OAuth.new(
        "access-token",
        "refresh-token",
        DateTime.utc_now() |> DateTime.add(3600, :second),
        "account-123"
      )

    assert {:ok, token} = CodexOAuth.store_credentials(credentials)

    assert token.provider == "openai-codex"
    assert token.kind == "oauth"
    assert token.token == "access-token"
    assert token.refresh_token == "refresh-token"
    assert token.account_id == "account-123"
    assert token.label == "codex-login"
  end

  test "runs implemented API key and token row actions" do
    {:ok, key, _raw_key} = Storage.create_key("admin-delete")
    {:ok, token} = Storage.add_token("openai", "api-key", "admin-token")

    assert {:ok, %ActionResult.Refresh{}} =
             LLMProxy.Admin.run_action(
               "provider_token",
               "disable",
               %{id: to_string(token.id)},
               %{}
             )

    [disabled] = Storage.list_tokens(%{provider: "openai"})
    assert disabled.enabled == false

    assert {:ok, %ActionResult.Refresh{}} =
             LLMProxy.Admin.run_action(
               "provider_token",
               "enable",
               %{id: to_string(token.id)},
               %{}
             )

    [enabled] = Storage.list_tokens(%{provider: "openai"})
    assert enabled.enabled == true

    assert {:ok, %ActionResult.Refresh{}} =
             LLMProxy.Admin.run_action(
               "provider_token",
               "remove",
               %{id: to_string(token.id)},
               %{}
             )

    assert Storage.list_tokens(%{provider: "openai"}) == []

    assert {:ok, %ActionResult.Refresh{}} =
             LLMProxy.Admin.run_action("api_key", "delete", %{id: key.id}, %{})

    assert Storage.list_keys() == []
  end

  defp socket_path(name) do
    Path.join(
      System.tmp_dir!(),
      "llm-proxy-admin-#{name}-#{System.unique_integer([:positive])}.sock"
    )
  end
end
