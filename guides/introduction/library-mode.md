# Library Mode

Library mode embeds LLMProxy in an existing Elixir application. The host application owns storage and supervision; LLMProxy supplies provider execution, routing, authentication, accounting, and optional HTTP routes.

Use this mode when calls originate inside one application or when an existing Phoenix endpoint should expose the gateway.

## Host application configuration

Point LLMProxy at the host repo. The repo must already be supervised by the host application.

```elixir
# config/runtime.exs
config :llm_proxy,
  repo: MyApp.Repo,
  http_enabled: false,
  master_key: System.fetch_env!("LLM_PROXY_MASTER_KEY"),
  providers: %{
    "openai" => %{api_keys: System.fetch_env!("OPENAI_API_KEYS")},
    "anthropic" => %{api_keys: System.fetch_env!("ANTHROPIC_API_KEYS")}
  },
  models: [
    fast: [
      routing: :ordered,
      routes: [
        [to: :openai, model: "gpt-4.1-mini"],
        [to: :anthropic, model: "claude-3-5-haiku-20241022", order: 2]
      ]
    ]
  ]
```

Set `http_enabled: false` unless you intentionally want LLMProxy to start its own Cowboy listener. Phoenix-mounted routes do not require that listener.

LLMProxy detects the configured repo adapter through `repo.__adapter__/0`. The storage implementation supports SQLite, PostgreSQL, MySQL-compatible adapters, and QuackDB/DuckDB. Database adapter dependencies belong to the host application.

## Migrations

With Igniter installed, add LLMProxy's migration path to the host aliases:

```bash
mix igniter.install llm_proxy
```

The installer adds `mix llm_proxy.migrate` and updates conventional `ecto.setup` and test aliases to include both migration directories:

```text
priv/repo/migrations
deps/llm_proxy/priv/repo/migrations
```

Run migrations:

```bash
mix llm_proxy.migrate
```

Without Igniter, pass both paths explicitly:

```bash
mix ecto.migrate \
  --migrations-path priv/repo/migrations \
  --migrations-path deps/llm_proxy/priv/repo/migrations
```

Release migration code should pass both directories to `Ecto.Migrator.run/4`. Do not copy LLMProxy migrations into the host directory; keeping the dependency path avoids duplicate versions and makes upgrades explicit.

## In-process calls

`LLMProxy.chat/2` accepts a prompt, a message list, or a `ReqLLM.Context`:

```elixir
{:ok, response} =
  LLMProxy.chat("Summarize the last deployment",
    model: "fast",
    api_key: llm_proxy_key,
    temperature: 0.2,
    max_tokens: 400,
    metadata: %{"deployment_id" => "dep_123"},
    tags: ["operations"]
  )

text = ReqLLM.Response.text(response.message)
trace_id = response.trace_id
usage = response.usage
```

Pass either:

- `:api_key` with a raw LLMProxy key or an existing API-key schema/map; or
- `:actor` with `%LLMProxy.Actor{}`.

The key determines model access, quotas, budget limits, attribution, and stored usage. The master key is accepted for bootstrap and operator calls but should not be distributed to ordinary clients.

## ReqLLM provider

LLMProxy registers itself as the ReqLLM provider `:llm_proxy` when the application starts:

```elixir
model = %{
  provider: :llm_proxy,
  id: "fast",
  model: "fast"
}

{:ok, response} =
  ReqLLM.Generation.generate_text(model, "Hello",
    api_key: llm_proxy_key
  )

ReqLLM.Response.text(response)
```

This still executes in-process. It is useful when application code already speaks ReqLLM and should gain LLMProxy routing and accounting without an HTTP round trip.

## Phoenix routes

Add Phoenix as a dependency in the host, then import LLMProxy's router macros:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  use LLMProxy.Router

  scope "/" do
    pipe_through :api
    llm_proxy "/llm", setup: false
  end
end
```

The mount exposes core routes below `/llm`, including:

```text
/llm/v1/models
/llm/v1/chat/completions
/llm/v1/messages
/llm/v1/responses
/llm/v1/moderations
/llm/v1/feedback
```

Generation, moderation, and feedback routes authenticate with `Authorization: Bearer <key>` or `x-api-key`. Model listing is public. Setup helper routes remain disabled unless `setup: true` is passed.

## SafeRPC calls

A remote BEAM consumer can call the same execution path over a Unix socket:

```elixir
{:ok, request} = LLMProxy.Provider.chat_request("Hello", model: "fast")

{:ok, response} =
  SafeRPC.call(socket, {LLMProxy, :chat}, request,
    meta: %{api_key: llm_proxy_key},
    timeout: 30_000
  )
```

Configure `:rpc_socket` in the LLMProxy host to start its SafeRPC server. The socket is also the boundary used by the optional Incant admin host.

## Custom storage

Advanced hosts can replace the Ecto-backed implementation:

```elixir
config :llm_proxy,
  storage: MyApp.LLMProxyStorage
```

The module implements `LLMProxy.Storage.Adapter`. Keep provider execution independent of the storage implementation; callers should use the public `LLMProxy.Storage` facade rather than concrete repo modules.

## Continue reading

- [Providers and Routing](../features/providers-and-routing.md)
- [Governance and Observability](../features/governance-and-observability.md)
- [Admin Integration](../features/admin-integration.md)
- [Architecture](../internals/architecture.md)
