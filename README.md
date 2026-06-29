# LLM Proxy

Embeddable Elixir/Phoenix LLM gateway with usage tracking, quotas, provider token pools, and OpenAI-compatible HTTP routes.

`LLMProxy.Provider` is the primary in-process execution boundary. HTTP routing is a thin adapter around it, so Phoenix apps can use the same accounting, fallback, and provider dispatch without localhost HTTP calls.

## What it provides

- **In-process Elixir API** via `LLMProxy.Provider` and `LLMProxy.chat/2`
- **ReqLLM provider** registered as `:llm_proxy`
- **Plug HTTP API** for OpenAI-compatible clients
- **OpenAI Chat Completions** (`/v1/chat/completions`) with streaming support
- **Anthropic Messages** (`/v1/messages`) with streaming support
- **OpenAI Responses** (`/v1/responses`) with streaming support
- **OpenAI Moderations** (`/v1/moderations`)
- **Provider system** with model-based dispatch, retries, fallback models, and catalog aliases
- **Catalog routing** with ordered/shuffled deployments, per-deployment timeouts, and circuit breakers
- **Guardrail hooks** for request/response/stream policy without bundling a policy engine
- **Deterministic cache hooks** for pluggable non-stream response caching
- **Token pool** with multiple upstream API keys, stable user pinning, and cooldowns
- **Usage tracking** for input/output/cache tokens and estimated cost
- **Quota enforcement** with per-key token/message/cache controls
- **API key and provider token management through Incant admin surfaces**

## Architecture

```text
Local Elixir calls       ReqLLM calls           HTTP clients
LLMProxy.chat/2          provider: :llm_proxy   /v1/chat/completions
       │                       │                       │
       └──────────────┬────────┴──────────────┬────────┘
                      ▼                       ▼
              LLMProxy.Provider        HTTP route adapters
                      │
                      ▼
       provider resolution / quota / fallback / usage / tracing
                      │
                      ▼
             OpenAI / Anthropic / OpenRouter
```

Core request contracts use `ReqLLM.Context` and `ReqLLM.Message` internally. Wire maps stay at HTTP/provider boundaries.

## Local Elixir usage

```elixir
{:ok, response} =
  LLMProxy.chat("Explain GenServers briefly",
    model: "openai/gpt-4.1-mini",
    api_key: raw_or_loaded_llm_proxy_key
  )

response.body
response.usage
```

## ReqLLM usage

Local in-process provider:

```elixir
model = %{
  provider: :llm_proxy,
  id: "openai/gpt-4.1-mini",
  model: "openai/gpt-4.1-mini"
}

{:ok, response} =
  ReqLLM.Generation.generate_text(model, "Hello",
    api_key: raw_llm_proxy_key
  )

ReqLLM.Response.text(response)
```

Remote BEAM consumers should use SafeRPC with ordinary LLMProxy request structs:

```elixir
{:ok, descriptor} = SafeRPC.describe(socket)
{:ok, request} = LLMProxy.Provider.chat_request("Hello", model: "fast")
{:ok, response} = SafeRPC.call(socket, {LLMProxy, :chat}, request, meta: %{api_key: raw_llm_proxy_key})
```

## Phoenix embedding

Mount core LLM routes in a host Phoenix router:

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

Dev/test storage defaults to the bundled SQLite repo. Standalone production releases use the bundled QuackDB/DuckDB repo and supervise a local Quack server. QuackDB generates the local Quack protocol token at runtime and LLMProxy injects it into the bundled repo; operators do not configure a `QUACKDB_TOKEN` secret.

SQLite remains an optional dependency for downstream apps that want a lightweight embedded repo in non-production hosts:

```elixir
{:llm_proxy, "~> ..."},
{:ecto_sqlite3, "~> 0.17"}
```

Host Phoenix apps can instead provide their own Ecto repo:

```elixir
config :llm_proxy,
  repo: MyApp.Repo
```

LLMProxy detects the configured repo adapter with `repo.__adapter__/0` for SQL differences and currently supports SQLite, PostgreSQL, MySQL-compatible, and QuackDB/DuckDB Ecto adapters. PostgreSQL/MySQL adapter dependencies should come from the host app.

The public `LLMProxy.Storage` module is a facade. The default implementation is `LLMProxy.Storage.Ecto`, and advanced hosts can provide a custom storage adapter:

```elixir
config :llm_proxy,
  storage: MyApp.LLMProxyStorage
```

Custom storage modules implement `LLMProxy.Storage.Adapter`.

To install or upgrade the storage schema in a host repo, run the Igniter installer:

```bash
mix igniter.install llm_proxy
```

The installer adds a `mix llm_proxy.migrate` alias that includes both the host application's migration path and LLMProxy's dependency migration path. Without the installer, pass both paths directly:

```bash
mix ecto.migrate \
  --migrations-path priv/repo/migrations \
  --migrations-path deps/llm_proxy/priv/repo/migrations
```

Release code can do the same through `Ecto.Migrator.run/4` by passing both migration directories.

Route groups:

- `core: true` — models, chat, messages, responses, moderations
- `setup: true` — optional setup helper routes; disabled by default

Admin surfaces are exposed through `LLMProxy.Admin` and Incant/SafeRPC, not through public service HTTP routes.

## Release artifacts

Use ReleaseKit to build the standalone OTP release tarball and manifest consumed by HostKit deployments:

```bash
MIX_ENV=prod mix release_kit.artifact --out-dir _build/prod/artifacts
```

This assembles the Mix release and writes:

```text
_build/prod/artifacts/llm_proxy-<version>.tar.gz
_build/prod/artifacts/llm_proxy.etf
```

## Standalone HTTP API

`LLMProxy.Router` can also be run as the app router.

### Core routes

- `GET /health`
- `GET /v1/models`
- `GET /models`
- `POST /v1/chat/completions`
- `POST /chat/completions`
- `POST /v1/messages`
- `POST /v1/responses`
- `POST /v1/moderations`
- `POST /moderations`
- `POST /feedback` / `POST /v1/feedback` — submit trace feedback by `request_id` or `trace_id`

### Admin surface

Administrative resources for keys, provider tokens, traces, messages, and operational dashboards are exposed by `LLMProxy.Admin` for Incant/SafeRPC consumers. They are not mounted on the public HTTP API.

### Optional setup routes

`/setup` is not mounted by default in embeddable router usage. It exists for local/onboarding helper flows such as install script, model listing, and client config snippets.

## Cache hooks

Host apps can configure an optional deterministic cache adapter for non-stream provider calls:

```elixir
config :llm_proxy,
  cache: MyApp.LLMCache,
  cache_policy: [
    ttl_ms: 60_000,
    models: %{"no-cache-model" => [enabled: false]}
  ]
```

```elixir
defmodule MyApp.LLMCache do
  @behaviour LLMProxy.Cache

  def get(key, context), do: :miss
  def put(key, response, context), do: :ok
end
```

Cache keys are derived from the normalized request and resolved deployment attempts. Adapters return `{:hit, %LLMProxy.Response{}}` or `:miss`. Requests can bypass cache with metadata such as `%{"no_cache" => true}` or override TTL with `%{"cache_ttl_ms" => 30_000}`.

## Guardrail hooks

Host apps can configure policy modules around the provider execution path:

```elixir
config :llm_proxy, guardrails: [MyApp.LLMPolicy]
```

```elixir
defmodule MyApp.LLMPolicy do
  @behaviour LLMProxy.Guardrail

  def before_request(request, _context), do: {:ok, request}
  def after_response(response, _context), do: {:ok, response}
  def on_stream_event(event, _context), do: {:ok, event}
end
```

Return `{:error, reason}` from a hook to reject the request/response. Returning `{:ok, nil}` from `on_stream_event/2` filters a stream chunk.

## Catalog routing

Public model names can be backed by one or more upstream deployments. Embedded apps can use the readable `:models` config shape; LLMProxy normalizes it into the internal catalog at boot:

```elixir
config :llm_proxy,
  models: [
    fast: [
      routing: :lowest_cost,
      routes: [
        [
          to: :openai,
          model: "gpt-4o-mini",
          timeout: 15_000,
          failure_threshold: 3,
          cooldown_ms: 30_000
        ],
        [to: :anthropic, model: "claude-3-haiku-20240307", order: 2]
      ]
    ]
  ]
```

Codex subscription models should also use catalog routing instead of relying on a static model list:

```elixir
config :llm_proxy,
  models: [
    codex: [route: [to: :openai_codex, model: "gpt-5.3-codex-spark"]]
  ]
```

The lower-level `:catalog` shape with provider modules and `upstream_model` remains supported for existing applications.

Routing strategies:

- `:ordered` — stable ordered fallback by deployment `order`
- `:shuffle` — shuffle deployments within each `order` group
- `:round_robin` — rotate deployments within each `order` group
- `:weighted_shuffle` — weighted random order within each `order` group using deployment `weight`
- `:lowest_cost` — sort deployments within each `order` group by LLMDB input+output pricing

Retryable provider failures and timeouts open a deployment-level circuit breaker after `failure_threshold` failures. Open deployments are skipped until `cooldown_ms` elapses.

## Bundled providers

- **OpenAI** — GPT/o-series models via standard API key
- **OpenAI Codex** — ChatGPT subscription Codex backend via OAuth token; streaming uses ReqLLM's Responses WebSocket transport
- **Anthropic** — Claude models via standard API key
- **OpenRouter** — OpenRouter models via OpenAI-compatible API

Additional upstream providers can be registered with `LLMProxy.Providers.Registry`.

## Configuration

See [`docs/architecture.md`](docs/architecture.md) for the module hierarchy and boundary rules. See [`docs/providers.md`](docs/providers.md) for custom provider authoring. See [`docs/roadmap.md`](docs/roadmap.md) for standalone release configuration direction.

Standalone releases also load optional data config from `/etc/llm-proxy/config.toml`; override the path with `LLM_PROXY_CONFIG_TOML`. Embedded/library users should continue to use ordinary `config :llm_proxy` application config.

Environment variables can be loaded from `.env` through Dotenvy.

| Variable | Description |
|---|---|
| `PORT` | Server port in prod, default `4000` |
| `MASTER_KEY` | Admin key |
| `DATABASE_PATH` | DuckDB database path for standalone QuackDB storage in prod, default `./llm_proxy.duckdb` |
| `PUBLIC_URL` | Public base URL used by setup helpers and provider headers |
| `OPENAI_API_KEYS` | Comma-separated OpenAI API keys |
| `OPENAI_CODEX_TOKENS` | Comma-separated ChatGPT/OpenAI OAuth tokens for Codex. Plain access tokens are accepted; refreshable entries use `access|refresh|expires_ms|account_id` (`account_id` optional). Standalone releases can also run `bin/codex_login` to sign in interactively. |
| `ANTHROPIC_API_KEYS` | Comma-separated Anthropic API keys |
| `OPENROUTER_API_KEYS` | Comma-separated OpenRouter API keys |
| `LLM_FALLBACKS` | JSON map of model fallback chains |
| `LLM_MAX_RETRIES` | Number of fallback models to try, default `1` |

Runtime defaults can also be overridden from Elixir config. Provider keys may be atoms or strings; `:openai_codex` normalizes to the bundled `"openai-codex"` provider.

```elixir
config :llm_proxy,
  token_cooldown_ms: :timer.hours(4),
  deployment_failure_threshold: 3,
  deployment_cooldown_ms: :timer.seconds(30),
  provider_receive_timeout_ms: :timer.minutes(10),
  remote_timeout_ms: :timer.seconds(30),
  providers: [
    anthropic: [
      base_url: "https://api.anthropic.com/v1",
      api_version: "2023-06-01",
      beta: "fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14",
      conversion_defaults: [max_tokens: 4096]
    ],
    openai: [base_url: "https://api.openai.com/v1"],
    openai_codex: [base_url: "https://chatgpt.com/backend-api"],
    openrouter: [base_url: "https://openrouter.ai/api/v1"]
  ]
```

HTTP generation routes use Plug request IDs for correlation. Incoming `x-request-id` is reused when valid; otherwise `Plug.RequestId`/`LLMProxy.Trace` generates one. The same value is returned as `x-request-id` and `x-llm-proxy-trace-id`; local calls expose it as `response.trace_id`.

## Setup

```bash
mix setup
mix run --no-halt
```

## Development

```bash
mix test
mix ci            # Compile, format check, test, Credo, Dialyzer, ExDNA, Reach
mix format
```

Test files mirror source structure under `test/llm_proxy/**`.

## Direction

LLMProxy intentionally focuses on a smaller surface than LiteLLM or Portkey:

- embeddable in Phoenix apps
- Elixir/ReqLLM-native execution, including remote BEAM calls
- HTTP compatibility where useful
- strict internal contracts
- local ownership of usage and quota data

Planned gateway features are tracked in `docs/roadmap.md`.
