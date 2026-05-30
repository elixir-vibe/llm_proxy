# Roadmap

LLMProxy is an embeddable Elixir/Phoenix LLM gateway. LiteLLM and Portkey are useful references, but the project should stay library-first rather than becoming a broad hosted AI platform.

## Product boundary

In scope:

- in-process `LLMProxy.Provider` execution
- ReqLLM provider integration
- Phoenix router embedding
- OpenAI/Anthropic-compatible HTTP adapters
- model/provider routing
- key governance, budgets, quotas, usage, tracing
- provider token pool management

Out of scope for core:

- non-LLM service proxies
- prompt management studio
- hosted SSO/RBAC product surface
- MCP/agent gateway until there is a concrete Elixir use case

## LiteLLM/Portkey parity targets

### 1. Model catalog

Introduce a first-class catalog separating public model names from upstream deployments.

Potential shape:

```elixir
%LLMProxy.Catalog.Model{
  name: "fast",
  deployments: [
    %LLMProxy.Catalog.Deployment{
      provider: LLMProxy.Providers.OpenAI,
      upstream_model: "gpt-4.1-mini",
      order: 1,
      token_pool: "openai-prod",
      timeout_ms: 30_000
    }
  ]
}
```

Useful ideas to adapt:

- LiteLLM model groups and aliases
- Portkey provider slugs like `@openai-prod/gpt-4o`
- hidden aliases for backwards-compatible model names
- per-model access controls

### 2. Budgets and rate limits

Replace rigid quota fields with composable limits while keeping simple defaults easy.

Targets:

- token windows: input/output/cache/messages
- cost windows: `$5 / 4h`, `$100 / 30d`
- per-model budgets
- per-key budgets
- future actor/team budgets
- RPM/TPM limits
- max concurrent requests

Potential shape:

```elixir
limits: [
  %{metric: :cost_usd, window: "24h", max: 10.0},
  %{metric: :input_tokens, window: "4h", max: 100_000},
  %{metric: :requests, window: "1m", max: 60}
]
```

### 3. Routing strategies

Current behavior supports provider resolution and fallback chains. Add explicit routing strategies over catalog deployments.

Targets:

- ordered fallback
- round robin
- random shuffle
- least busy
- cooldown-aware routing
- lowest cost
- latency-aware routing
- request timeout per deployment

### 4. Circuit breakers

Move beyond single-token cooldowns to deployment-level health state.

Targets:

- open/half-open/closed breaker state
- failure threshold per deployment
- cooldown duration
- retry-after handling
- observable breaker events

### 5. Caching

Start with deterministic cache before semantic cache.

Targets:

- opt-in request cache
- cache key from normalized request body + model/catalog target
- per-key or per-model cache policy
- usage/tracing metadata showing cache hits

Semantic caching should remain optional and not be part of the initial core.

### 6. Guardrail hooks

Keep guardrails as behaviours/hooks, not a bundled policy engine.

Potential callbacks:

```elixir
c:LLMProxy.Guardrail.before_request/2
c:LLMProxy.Guardrail.after_response/3
c:LLMProxy.Guardrail.on_stream_event/3
```

Targets:

- deterministic allow/deny/mask hooks
- provider-independent request/response shape
- metadata for trace records

### 7. Observability

Current storage has usage logs, traces, message logs, and basic telemetry. Improve it without locking users into a hosted product.

Targets:

- structured trace IDs surfaced in HTTP response headers
- OpenTelemetry spans for routing, provider calls, retries, fallback, cache, guardrails
- feedback API linked to trace IDs
- export hooks for external analytics

### 8. Remote BEAM calls

After `LLMProxy.Provider` stabilizes, add a remote node wrapper over the same in-process API.

Potential shape:

```elixir
LLMProxy.Remote.chat(:proxy@host, messages, opts)
LLMProxy.Remote.call(:proxy@host, request, actor, opts)
```

First version can use `:erpc.call/4`. Streaming can follow with a process-backed protocol.

## Near-term order

1. Update docs and test layout to match the current architecture.
2. Add `LLMProxy.Catalog` structs and config loader without changing routing behavior yet.
3. Migrate provider registry reads to catalog-aware resolution.
4. Replace quota fields with a limit evaluator while keeping migration-compatible schema fields.
5. Add timeout and circuit breaker state.
6. Add explicit routing strategy modules.
