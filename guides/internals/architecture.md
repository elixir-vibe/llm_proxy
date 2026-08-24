# Architecture

LLMProxy has one provider-execution boundary with several transport adapters around it, including local Unix-socket calls through [SafeRPC](https://hexdocs.pm/safe_rpc). Authentication, quota checks, policy, routing, accounting, and tracing do not belong in HTTP-only code.

## Request path

```text
LLMProxy.chat/2    ReqLLM provider    HTTP routes    SafeRPC
       │                 │                │             │
       └─────────────────┴────────┬───────┴─────────────┘
                                  ▼
                         LLMProxy.Provider
                                  │
                       actor and API-key lookup
                                  │
                    quota and public-model access
                                  │
                       before-request guardrails
                                  │
                  per-key concurrent admission
                                  │
                      cache key and catalog plan
                                  │
                  timeout / retry / fallback / circuit
                                  │
                    response and stream normalization
                                  │
                  guardrails / cache / usage / tracing
                                  │
                         caller-specific response
```

Core request contracts use `ReqLLM.Context`, `ReqLLM.Message`, and `LLMProxy.Protocol.Request`. OpenAI and Anthropic wire maps stay at protocol and transport boundaries.

## Module map

```text
LLMProxy
├── Provider                 in-process execution boundary and ReqLLM provider
│   ├── Credential           redacted request-scoped provider credential
│   └── TokenCodec           at-rest credential codec and key migration tools
├── HTTP
│   ├── Router               standalone Plug router
│   ├── RouteSpec            route table shared with Phoenix
│   └── Routes               protocol adapters
├── Phoenix.Router           Phoenix forwarding macros
├── Providers
│   ├── Registry             provider/model lookup and catalog resolution
│   ├── Execution            attempts, fallback, timeout, and retry handling
│   ├── CircuitBreaker       deployment health state
│   └── Routing              deployment ordering strategies
├── Protocol                 OpenAI/Anthropic request normalization
├── Catalog                  public model aliases and deployment data
├── TokenPool                credential selection and cooldown state
├── Cache                    adapter, deterministic key, and policy
├── GuardrailPipeline        request, response, and stream policy hooks
├── ConcurrencyLimiter       monitored per-key request and stream leases
├── Accounting               usage, spend, traces, and message recording
├── Telemetry                telemetry events and OpenTelemetry spans
├── Stream                   normalized events, SSE writing, and heartbeats
├── Storage                  public facade and adapter boundary
├── Admin                    optional Incant resources and dashboard
└── RPC                      SafeRPC server for admin and operations
```

## Transport adapters

### Local Elixir

`LLMProxy.chat/2` normalizes a prompt or ReqLLM context, then calls `LLMProxy.Provider`. It returns `%LLMProxy.Response{}` with the normalized ReqLLM response, provider identity, usage, trace ID, and cache metadata.

### ReqLLM

`LLMProxy.Provider` registers as ReqLLM provider `:llm_proxy`. The adapter builds an internal request and halts the Req pipeline with the response produced by the same provider boundary.

A ReqLLM call can execute locally or pass its request through SafeRPC when a client/socket option is provided.

### HTTP

`LLMProxy.HTTP.RouteSpec` is shared by the standalone Plug router and Phoenix macros. Route modules authenticate, parse wire requests, call the provider boundary, and render protocol-shaped responses or SSE events.

HTTP modules should not implement provider selection, accounting, or fallback.

### SafeRPC

SafeRPC exposes typed operation tuples over a local Unix socket. Ordinary chat calls target `LLMProxy`; remote admin operations target `LLMProxy.Admin`; drain operations target `LLMProxy.Ops`.

The socket transports portable request and response data. Repos, schemas, callbacks, policies, and side effects remain in the LLMProxy service VM.

## Catalog and providers

The catalog separates public model identity from deployment identity:

```elixir
%LLMProxy.Catalog.Model{
  name: "fast",
  deployments: [
    %LLMProxy.Catalog.Deployment{
      provider_name: "openai-primary",
      provider: LLMProxy.Providers.ReqLLM,
      upstream_model: "gpt-4.1-mini",
      token_pool: "openai-production",
      timeout_ms: 30_000
    }
  ]
}
```

Named providers with an `adapter` execute through `LLMProxy.Providers.ReqLLM`. Built-in modules remain for native or specialized integrations.

Deployment attempts carry provider identity, upstream model, token pool, timeout, order, weight, and circuit-breaker settings. This keeps credential selection and health state attached to the route that needs them.

## Storage

`LLMProxy.Storage` delegates to `config :llm_proxy, storage: ...`. The default `LLMProxy.Storage.Ecto` implementation uses `LLMProxy.Storage.Repo`, which delegates to the configured Ecto repo.

```text
LLMProxy.Storage
       │
       ▼
configured storage adapter
       │
       ▼
LLMProxy.Storage.Ecto
       │
       ▼
LLMProxy.Storage.Repo
       │
       ▼
host repo / bundled SQLite / bundled QuackDB
```

Library hosts usually provide their existing repo. The standalone production release uses the bundled QuackDB repo and supervises a managed local QuackDB process.

Provider-token schemas contain stored values only. A configured token codec
encodes writes before Ecto receives them. The token pool selects a stored row and
decodes it into a redacted `LLMProxy.Provider.Credential` only at the provider
boundary. Admin lists and schema inspection do not receive plaintext values.

Database-specific queries and migrations branch on the configured repo adapter. Provider execution depends on the storage facade, not a concrete database.

## Resource cleanup test budget

The loopback resource stress test repeats normal, complete streaming, and
client-canceled streaming requests in one BEAM. Its listener uses two acceptors
and sixteen maximum connections. Its client pool uses one connection. The test
requires an inherited BEAM file-descriptor limit of 128 and reports the measured
limit when it is lower. After warm-up, the allowed growth is two BEAM ports and
eight processes. All provider work, drain leases, optional concurrency leases,
and the test listener must return to zero or stop before the test completes.

## Optional integrations

Optional modules use compile-time availability checks:

- Incant admin modules load only when Incant is installed.
- SQLite repo modules load only when `ecto_sqlite3` is installed.
- Phoenix router integration requires Phoenix in the host.
- Igniter installation support requires Igniter.

The gateway core remains usable without those packages.

## Ownership rules

- Provider execution and fallback belong under `LLMProxy.Provider` and `LLMProxy.Providers`.
- HTTP modules parse and render only.
- Phoenix embedding helpers belong under `LLMProxy.Phoenix`.
- Deployment selection belongs under `LLMProxy.Providers.Routing`, not Phoenix routing.
- Endpoint/model differences belong in provider data unless they require a new protocol.
- Storage access goes through `LLMProxy.Storage` or `LLMProxy.Storage.Repo` facades.
- `LLMProxy.Admin` is the only service-owned admin surface; do not add a second public admin API.
- SafeRPC transports operations but does not move executable service internals between VMs.
