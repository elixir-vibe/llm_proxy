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

Current behavior supports catalog-aware routing over provider deployments.

Implemented:

- ordered fallback
- random shuffle within order groups
- round robin within order groups
- weighted shuffle within order groups
- lowest cost within order groups using LLMDB pricing
- cooldown-aware routing through deployment circuit breakers
- request timeout per deployment

Future targets:

- least busy
- latency-aware routing

### 4. Circuit breakers

Move beyond single-token cooldowns to deployment-level health state.

Implemented:

- open/half-open/closed breaker state
- failure threshold per deployment
- cooldown duration
- retry-after handling for token and deployment cooldowns
- observable breaker events

### 5. Caching

Start with deterministic cache before semantic cache.

Implemented:

- opt-in request cache via `config :llm_proxy, cache: MyApp.Cache`
- cache key from normalized request + resolved deployment attempts
- strict cache adapter contract using `%LLMProxy.Response{}`
- cache hit metadata on `LLMProxy.Response.cache_hit`
- per-model cache policy
- request metadata cache bypass and TTL override
- TTL hints passed to cache adapters

Future targets:

- per-key cache policy
- usage/tracing metadata for cache hit analytics

Semantic caching should remain optional and not be part of the initial core.

### 6. Guardrail hooks

Keep guardrails as behaviours/hooks, not a bundled policy engine.

Implemented callbacks:

```elixir
c:LLMProxy.Guardrail.before_request/2
c:LLMProxy.Guardrail.after_response/2
c:LLMProxy.Guardrail.on_stream_event/2
```

Implemented:

- deterministic allow/deny/mask hooks
- provider-independent request/response shape via `%LLMProxy.Protocol.Request{}`, `%LLMProxy.Response{}`, and `%LLMProxy.Stream.Event{}`
- context metadata for route/model/api key/provider

### 7. Observability

Current storage has usage logs, traces, message logs, and basic telemetry. Improve it without locking users into a hosted product.

Implemented:

- structured trace IDs surfaced in HTTP generation route headers and local `LLMProxy.Response`
- telemetry events for routing attempts and circuit breaker transitions
- OpenTelemetry provider spans with trace ID attributes, including native Messages/Responses/Moderations paths

Future targets:

- spans for cache and guardrails after those hooks exist
- feedback API linked to trace IDs
- export hooks for external analytics

### 8. Remote BEAM calls

SafeRPC is the remote BEAM communication layer for LLMProxy.

```elixir
{:ok, request} = LLMProxy.Provider.chat_request(messages, model: "fast")
SafeRPC.call(socket, {LLMProxy, :chat}, request, meta: %{api_key: raw_key})
```

### 9. Standalone release configuration

Keep library/embedded config and standalone operator config separate.

Implemented for embedded apps:

- readable `config :llm_proxy, providers: [...]` shape
- readable `config :llm_proxy, models: [...]` shape
- compatibility with lower-level `:catalog` deployments

Implemented for standalone releases:

- optional `/etc/llm-proxy/config.toml` loaded through `LLMProxy.Config.Provider`
- override path with `LLM_PROXY_CONFIG_TOML`
- TOML decoding uses the `:toml` package with string keys and explicit key normalization
- embedded/library mode does not search `/etc` or load standalone config files by default

Future standalone direction:

- consider a trusted Elixir config DSL only as an expert escape hatch
- keep provider tokens in storage/admin surfaces; env token variables should remain bootstrap/import compatibility

Candidate TOML shape:

```toml
[providers.openai-codex]
base_url = "https://chatgpt.com/backend-api"

[[models]]
name = "codex"

[[models.routes]]
to = "openai-codex"
model = "gpt-5.3-codex-spark"
```

## Near-term order

1. ✅ Update docs and test layout to match the current architecture.
2. ✅ Add `LLMProxy.Catalog` structs and config loader.
3. ✅ Migrate provider registry reads to catalog-aware resolution.
4. ✅ Replace quota fields with a limit evaluator while keeping migration-compatible schema fields.
5. ✅ Add timeout and circuit breaker state.
6. ✅ Add explicit routing strategies.
7. ✅ Add cache hooks.
8. ✅ Add guardrail behaviours.
9. ✅ Add remote BEAM calls.
