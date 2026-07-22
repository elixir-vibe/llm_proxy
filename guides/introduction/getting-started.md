# Getting Started

LLMProxy can run inside an existing Elixir application or as its own OTP service. Both modes use the same provider execution, routing, quota, usage, and tracing code.

## Requirements

- Elixir 1.17 or later
- An Ecto repo in library mode, or the bundled DuckDB/QuackDB storage in standalone mode
- At least one upstream provider credential
- A master key for bootstrap and operator access

Phoenix, SQLite, Igniter, and Incant are optional integrations.

## Install the package

Add LLMProxy to `mix.exs`:

```elixir
def deps do
  [
    {:llm_proxy, "~> 0.1"}
  ]
end
```

Fetch dependencies:

```bash
mix deps.get
```

## Choose a mode

### Library mode

Choose library mode when LLMProxy belongs to an existing Elixir or Phoenix application. The host owns the repo, release, endpoint, and configuration.

Configure the host repo and disable LLMProxy's separate Cowboy listener:

```elixir
# config/runtime.exs
config :llm_proxy,
  repo: MyApp.Repo,
  http_enabled: false,
  master_key: System.fetch_env!("LLM_PROXY_MASTER_KEY")
```

Run the installer to add migration aliases, then migrate:

```bash
mix igniter.install llm_proxy
mix llm_proxy.migrate
```

Continue with [Library Mode](library-mode.md).

### Standalone mode

Choose standalone mode when multiple applications or external clients need one gateway. The bundled release owns HTTP serving, DuckDB storage, provider credentials, and operational state.

A minimal runtime environment is:

```bash
export MASTER_KEY="replace-with-a-long-random-key"
export OPENAI_API_KEYS="sk-..."
export DATABASE_PATH="./llm_proxy.duckdb"
export PORT="4000"
```

Continue with [Standalone Mode](standalone-mode.md) and [Standalone Deployment](../deployment/standalone-deployment.md).

## Configure a model

Clients call public model names. Each public name routes to one or more upstream deployments.

Library configuration:

```elixir
config :llm_proxy,
  providers: %{
    "openai" => %{api_keys: System.fetch_env!("OPENAI_API_KEYS")}
  },
  models: [
    fast: [route: [to: :openai, model: "gpt-4.1-mini"]]
  ]
```

Standalone TOML:

```toml
[[models]]
name = "fast"

[[models.routes]]
to = "openai"
model = "gpt-4.1-mini"
```

Provider credentials are secrets. Put them in runtime environment variables or persisted provider-token storage, never in committed Elixir or TOML files.

## Make a request

In-process:

```elixir
{:ok, response} =
  LLMProxy.chat("Hello",
    model: "fast",
    api_key: System.fetch_env!("LLM_PROXY_MASTER_KEY")
  )

ReqLLM.Response.text(response.message)
```

HTTP:

```bash
curl http://127.0.0.1:4000/v1/chat/completions \
  -H "authorization: Bearer $MASTER_KEY" \
  -H "content-type: application/json" \
  -d '{"model":"fast","messages":[{"role":"user","content":"Hello"}]}'
```

The master key bypasses ordinary per-key quotas and is intended for bootstrap and operator access. Create scoped API keys for applications and users before production traffic.

## Verify the installation

Check the service and catalog:

```bash
curl http://127.0.0.1:4000/health
curl http://127.0.0.1:4000/v1/models
```

A successful generation should also produce usage and trace records in the configured storage. If OpenTelemetry export is enabled, the provider attempt carries the same LLMProxy trace ID returned to the caller.

## Next steps

- [Providers and Routing](../features/providers-and-routing.md)
- [Governance and Observability](../features/governance-and-observability.md)
- [Cache and Guardrails](../features/cache-and-guardrails.md)
- [Configuration Cheatsheet](../reference/configuration.cheatmd)
- [HTTP API Cheatsheet](../reference/http-api.cheatmd)
