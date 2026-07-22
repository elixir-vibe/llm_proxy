# LLMProxy

[![Hex.pm](https://img.shields.io/hexpm/v/llm_proxy.svg)](https://hex.pm/packages/llm_proxy) [![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/llm_proxy)

An Elixir-native LLM gateway for Phoenix applications and standalone services. Route one public model name across providers, enforce API-key budgets and quotas, pool upstream credentials, and record usage, cost, latency, and traces through the same execution path.

Use LLMProxy directly inside an Elixir application:

```elixir
{:ok, response} =
  LLMProxy.chat("Explain supervision trees in three sentences",
    model: "fast",
    api_key: llm_proxy_key
  )

ReqLLM.Response.text(response.message)
```

Or run it as an OpenAI-compatible service:

```bash
curl http://127.0.0.1:4000/v1/chat/completions \
  -H "authorization: Bearer $LLM_PROXY_KEY" \
  -H "content-type: application/json" \
  -d '{"model":"fast","messages":[{"role":"user","content":"Hello"}]}'
```

## Why LLMProxy

- **One core, two deployment modes.** Call `LLMProxy.chat/2` in-process, mount the routes in Phoenix, or run the bundled OTP release. Local, HTTP, ReqLLM, and [SafeRPC](https://hexdocs.pm/safe_rpc) calls share routing, accounting, and policy.
- **Stable model names over changing providers.** Map an alias such as `fast` to ordered, shuffled, round-robin, weighted, or lowest-cost deployments. Retryable failures fall through to healthy routes, with per-deployment timeouts and circuit breakers.
- **Governance you own.** API keys can restrict models and enforce token, message, cache, and spend limits. Usage, estimated cost, latency, messages, and traces stay in your configured storage.
- **Credentials stay isolated.** Provider token pools support multiple upstream keys, stable actor pinning, `Retry-After` cooldowns, and separate pools for services that happen to share a protocol.
- **Compatible where clients need it.** Serve OpenAI Chat Completions, Responses, Moderations, and Anthropic Messages, including streaming. Use the same gateway as a ReqLLM provider from Elixir.
- **Policy without a hosted platform.** Add deterministic cache and guardrail modules, export OpenTelemetry spans, and optionally expose operations through Incant.

## How it fits

```text
Elixir calls          ReqLLM calls          HTTP clients          Remote BEAM apps
LLMProxy.chat/2       provider: :llm_proxy  /v1/chat/completions  SafeRPC
       │                     │                       │                │
       └─────────────────────┴───────────┬───────────┴────────────────┘
                                         ▼
                                LLMProxy.Provider
                                         │
                   auth → quota → policy → cache → routing
                                         │
                    fallback → usage → cost → traces → telemetry
                                         │
                      OpenAI / Anthropic / OpenRouter / custom
```

`LLMProxy.Provider` is the execution boundary. HTTP routes translate wire protocols; they do not implement a second gateway path.

## Installation

Add LLMProxy to `mix.exs`:

```elixir
def deps do
  [
    {:llm_proxy, "~> 0.1"}
  ]
end
```

LLMProxy requires Elixir 1.17 or later. Phoenix, SQLite, Igniter, and Incant integrations are optional dependencies; add only the ones your deployment uses.

Choose a mode before configuring storage and serving:

- **Library mode** — use your application's Ecto repo and call LLMProxy in-process. Mount HTTP routes in Phoenix only when needed.
- **Standalone mode** — build the bundled OTP release with local DuckDB/QuackDB storage and its own HTTP listener.

See [Getting Started](https://hexdocs.pm/llm_proxy/getting-started.html) for the complete setup path.

## Library mode

Point LLMProxy at the host application's repo and disable its separate HTTP listener when you only need in-process calls or Phoenix-mounted routes:

```elixir
# config/runtime.exs
config :llm_proxy,
  repo: MyApp.Repo,
  http_enabled: false,
  master_key: System.fetch_env!("LLM_PROXY_MASTER_KEY"),
  providers: %{
    "openai" => %{api_keys: System.fetch_env!("OPENAI_API_KEYS")}
  },
  models: [
    fast: [route: [to: :openai, model: "gpt-4.1-mini"]]
  ]
```

Install migration aliases and migrate the host repo:

```bash
mix igniter.install llm_proxy
mix llm_proxy.migrate
```

Then call it directly:

```elixir
{:ok, response} =
  LLMProxy.chat("Summarize this incident",
    model: "fast",
    api_key: System.fetch_env!("LLM_PROXY_MASTER_KEY"),
    metadata: %{"incident_id" => "inc_123"},
    tags: ["operations"]
  )
```

To expose the same gateway through an existing Phoenix endpoint:

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

This mounts `/llm/v1/chat/completions`, `/llm/v1/messages`, `/llm/v1/responses`, `/llm/v1/moderations`, model listing, and feedback routes.

See [Library Mode](https://hexdocs.pm/llm_proxy/library-mode.html) for storage, migrations, ReqLLM, Phoenix, and SafeRPC examples.

## Standalone mode

The standalone release runs a local HTTP gateway backed by DuckDB through QuackDB. It listens on `127.0.0.1` and is intended to sit behind your reverse proxy or service mesh.

Configure secrets with environment variables:

```bash
export MASTER_KEY="replace-with-a-long-random-key"
export OPENAI_API_KEYS="sk-..."
export DATABASE_PATH="/var/lib/llm-proxy/llm_proxy.duckdb"
export PORT="4000"
```

Configure public providers and model aliases as data in `/etc/llm-proxy/config.toml`:

```toml
[providers.openai-primary]
adapter = "openai"
base_url = "https://api.openai.com/v1"
token_pool = "openai"

[[models]]
name = "fast"
routing = "ordered"

[[models.routes]]
to = "openai-primary"
model = "gpt-4.1-mini"
timeout = 30000
```

Credentials do not belong in TOML. Bootstrap named pools with `LLM_PROXY_PROVIDER_KEYS` or manage persisted tokens through the optional admin integration.

The release serves health, model, generation, moderation, and feedback routes. Streaming responses include heartbeats during upstream silence and preserve OpenAI or Anthropic event payloads.

See [Standalone Mode](https://hexdocs.pm/llm_proxy/standalone-mode.html) and [Standalone Deployment](https://hexdocs.pm/llm_proxy/standalone-deployment.html) for configuration, migrations, release commands, health checks, and shutdown draining.

## Routing and providers

A public model can target one or more deployments:

```elixir
config :llm_proxy,
  models: [
    fast: [
      routing: :lowest_cost,
      routes: [
        [
          to: :openai,
          model: "gpt-4.1-mini",
          timeout: 15_000,
          failure_threshold: 3,
          cooldown_ms: 30_000
        ],
        [to: :anthropic, model: "claude-3-5-haiku-20241022", order: 2]
      ]
    ]
  ]
```

Built-in providers cover OpenAI, Anthropic, OpenRouter, and OpenAI Codex OAuth. For another OpenAI-compatible service, declare a named provider with a ReqLLM `adapter`, `base_url`, and isolated `token_pool`; no provider module is required.

See [Providers and Routing](https://hexdocs.pm/llm_proxy/providers-and-routing.html) for routing semantics, custom endpoints, token pools, Codex OAuth, and native protocol extensions.

## Governance and observability

Every authenticated request runs through the same controls:

1. Resolve the actor and API key.
2. Check model access, quota windows, and budget limits.
3. Apply request guardrails and deterministic cache policy.
4. Select a healthy deployment and credential.
5. Execute with timeout, retry, fallback, and circuit-breaker handling.
6. Record usage, estimated cost, latency, trace IDs, messages, and optional bodies.
7. Emit OpenTelemetry spans and return the trace ID to the caller.

Incant support is optional. When installed, `LLMProxy.Admin` describes resources for API keys, provider tokens, traces, and messages plus an operations dashboard. A separate Incant host can consume those surfaces over SafeRPC; the public gateway does not expose an admin UI.

See [Governance and Observability](https://hexdocs.pm/llm_proxy/governance-and-observability.html), [Cache and Guardrails](https://hexdocs.pm/llm_proxy/cache-and-guardrails.html), and [Admin Integration](https://hexdocs.pm/llm_proxy/admin-integration.html).

## Documentation

- [Getting Started](https://hexdocs.pm/llm_proxy/getting-started.html)
- [Library Mode](https://hexdocs.pm/llm_proxy/library-mode.html)
- [Standalone Mode](https://hexdocs.pm/llm_proxy/standalone-mode.html)
- [Providers and Routing](https://hexdocs.pm/llm_proxy/providers-and-routing.html)
- [Governance and Observability](https://hexdocs.pm/llm_proxy/governance-and-observability.html)
- [Cache and Guardrails](https://hexdocs.pm/llm_proxy/cache-and-guardrails.html)
- [Admin Integration](https://hexdocs.pm/llm_proxy/admin-integration.html)
- [Standalone Deployment](https://hexdocs.pm/llm_proxy/standalone-deployment.html)
- [Configuration Cheatsheet](https://hexdocs.pm/llm_proxy/configuration.html)
- [HTTP API Cheatsheet](https://hexdocs.pm/llm_proxy/http-api.html)
- [Architecture](https://hexdocs.pm/llm_proxy/architecture.html)
- [API reference](https://hexdocs.pm/llm_proxy/api-reference.html)

## Development

```bash
mix deps.get
mix ci
```

## License

MIT © 2026 Danila Poyarkov
