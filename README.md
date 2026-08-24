# LLMProxy

[![Hex.pm](https://img.shields.io/hexpm/v/llm_proxy.svg)](https://hex.pm/packages/llm_proxy) [![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/llm_proxy)

A self-hosted, Elixir-native alternative to LiteLLM. Put one API in front of OpenAI, Anthropic, OpenRouter, Kimi Code, OpenAI Codex, and custom OpenAI-compatible providers—then switch models, add fallbacks, and control spend without changing every application that calls them.

LLMProxy gives applications stable model names such as `fast`, `smart`, or `cheap`. You decide where those names run, how traffic fails over, who may use them, and how much they may spend. Provider credentials and usage data stay in infrastructure you control.

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

- **Connect your applications once.** Point any OpenAI-compatible client at LLMProxy, use the Anthropic Messages API, or call it directly from Elixir. Stop duplicating provider adapters, authentication, retries, and usage tracking in every product.
- **Change providers without changing clients.** Applications request a public name such as `fast`; you can move it from OpenAI to Anthropic, OpenRouter, or a private endpoint by changing gateway configuration instead of application code.
- **Keep working when a provider does not.** Route across multiple models, providers, regions, or credentials. Bounded, replay-safe fallbacks, circuit breakers, and load-balancing strategies keep individual failures away from your users without silently replaying uncertain billable work.
- **Control spend before the invoice arrives.** Issue keys per application, customer, or team; restrict which models they can call; and enforce concurrent-request, token, request, cache, and dollar limits. See usage and estimated cost in one place.
- **Stop spreading provider keys across services.** Store upstream credentials in the gateway, rotate or pool them centrally, and give applications LLMProxy keys with only the access they need.
- **Self-host without adding a Python control plane.** Run the bundled OTP service as a LiteLLM-style gateway, or embed the same capabilities directly in an Elixir/Phoenix release. Your prompts, traces, credentials, and operational data remain under your control.

## One model name, many ways to serve it

Your clients call `fast`. LLMProxy can send that traffic to one preferred deployment, balance it across several, or fall back when an upstream is unavailable:

```text
                         ┌─ OpenAI / gpt-4.1-mini
client ── model: fast ───┼─ OpenRouter / google/gemini-2.5-flash
                         └─ private OpenAI-compatible endpoint
```

Change the route centrally and every client keeps working. The same public model name is available through OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, `LLMProxy.chat/2`, and ReqLLM.

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

See [Library Mode](https://hexdocs.pm/llm_proxy/library-mode.html) for storage, migrations, ReqLLM, Phoenix, and [SafeRPC](https://hexdocs.pm/safe_rpc) examples.

## Standalone mode

The standalone release runs a local HTTP gateway backed by DuckDB through QuackDB. It listens on `127.0.0.1` and is intended to sit behind your reverse proxy or service mesh.

Configure only secrets and the optional TOML location through the environment:

```bash
export MASTER_KEY="replace-with-a-long-random-key"
export LLM_PROXY_PROVIDER_KEYS='{"openai":["sk-..."]}'
export LLM_PROXY_CONFIG_TOML="/etc/llm-proxy/config.toml"
```

Configure standalone runtime settings, public providers, and model aliases as
data in that TOML file:

```toml
[server]
port = 4000
public_url = "https://llm.example.com"
body_limit_bytes = 32000000
rpc_socket = "/run/llm-proxy/rpc.sock"

[storage]
database = "/var/lib/llm-proxy/llm_proxy.duckdb"
quackdb_uri = "http://127.0.0.1:9494"
quackdb_endpoint = "quack:localhost:9494"

[routing]
max_retries = 1
replay_policy = "safe_only"
provider_connect_timeout_ms = 10000

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
6. Record usage, estimated cost, latency, and trace IDs without retaining prompts or model output unless content capture is explicitly enabled.
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
mix test         # deterministic unit and component tests
mix integration  # real provider integration; may use credentials and billable APIs
mix e2e          # real HTTP boundary through upstream response; may be billable
mix ci
```

Integration tests call real dependencies while bypassing the public HTTP gateway. End-to-end tests enter through the real HTTP listener and cover authentication, routing, storage-backed token selection, provider execution, and response serialization. Both layers are opt-in and skipped by the default test suite.

## License

MIT © 2026 Danila Poyarkov
