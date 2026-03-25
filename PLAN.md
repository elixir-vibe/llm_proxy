# LLM Proxy Improvement Plan

Comparison targets: [LiteLLM](https://litellm.ai/), [Langfuse](https://langfuse.com/)

## Boundary: Public vs Private

**`llm_proxy`** (public, open-sourceable) — generic LLM gateway:
- Protocol abstraction, provider registry, routing, cost tracking, observability
- API key management, quotas, admin UI
- Standard API-key-based providers (OpenAI, Anthropic, OpenRouter)

**`llm_proxy_private`** (private, personal use) — subscription proxying:
- OAuth token providers (Anthropic Claude Code, OpenAI Codex subscriptions)
- Claude Code identity injection, tool name rewriting
- Subscription usage endpoints (`/providers/usage/codex`, `/providers/usage/claude`)
- Any provider that uses subscription/OAuth tokens instead of API keys

**Rule**: anything involving OAuth tokens, subscription APIs, identity spoofing, or non-standard API access stays in `llm_proxy_private`. The public package must work as a clean, generic LLM gateway.

### Prerequisite: Move `Routes.ProviderUsage` to private

`lib/llm_proxy/routes/provider_usage.ex` fetches subscription usage from `chatgpt.com/backend-api/wham/usage` and `api.anthropic.com/api/oauth/usage`. This is entirely subscription/OAuth specific.

**Action**:
1. Move `lib/llm_proxy/routes/provider_usage.ex` → `llm_proxy_private` as `LLMProxyPrivate.Routes.ProviderUsage`
2. Remove `forward "/providers", to: LLMProxy.Routes.ProviderUsage` from `LLMProxy.Router`
3. Register via Dynamic in `LLMProxyPrivate.Application`:
   ```elixir
   Dynamic.register("/providers", LLMProxyPrivate.Routes.ProviderUsage)
   ```

---

## Phase 1: Protocol Abstraction

Extract protocol conversion into standalone modules so any client format can talk to any provider.

### Current state

- `Providers.Anthropic` has `to_anthropic_body/1` and `to_openai_response/2` baked in
- Three separate route files (`Chat`, `Messages`, `Responses`) in public package with duplicated stream piping
- Same three duplicated again in `llm_proxy_private` with extra logic (tool name rewriting, identity injection)
- Behaviour forces every provider to implement `to_openai_response/2` even for OpenAI-native providers
- No way to accept Anthropic-format requests and route to OpenAI, or vice versa

### Target

```
Request → Protocol.detect(conn) → Protocol.normalize(body) → internal format
    → Provider.call(internal_body) → provider-native response
    → Protocol.format_response(response, client_protocol) → client
```

### Steps

1. **Define internal request/response format** — superset of OpenAI and Anthropic fields:
   - Request: `%{model, messages, tools, temperature, max_tokens, stream, ...}`
   - Response: `%{id, content, tool_calls, usage, stop_reason, ...}`

2. **Create `LLMProxy.Protocol` behaviour**:
   ```elixir
   @callback detect(Plug.Conn.t()) :: boolean()
   @callback normalize_request(body :: map()) :: internal_request()
   @callback format_response(internal_response(), model :: String.t()) :: map()
   @callback format_stream_event(internal_event()) :: iodata() | nil
   ```

3. **Implement `Protocol.OpenAI`** — mostly passthrough with field normalization

4. **Implement `Protocol.Anthropic`** — move `to_anthropic_body/1` and `to_openai_response/2` here

5. **Simplify provider behaviour** — providers only deal with their native format:
   ```elixir
   @callback call(body :: map(), user_id :: String.t()) :: call_result()
   @callback stream(body :: map(), user_id :: String.t()) :: stream_result()
   @callback extract_usage(response :: map()) :: usage()
   @callback native_protocol() :: :openai | :anthropic
   ```

6. **Unify routes in public package** — merge `Chat`, `Messages`, `Responses` into single `Routes.Completion`:
   - Detect client protocol from route
   - Normalize to internal format
   - Look up provider, convert internal → provider-native if needed
   - Stream/respond, convert back to client protocol

7. **Keep `call_native/2` and `stream_native/2`** as optional callbacks — private package providers use these for subscription passthrough where the request must go through as-is

8. **Private package routes stay separate** — `LLMProxyPrivate.Routes.Messages` and `Responses` keep their Claude Code tool name rewriting and identity injection. They override the public routes via `Dynamic.register` (already working).

### Files touched

Public (`llm_proxy`):
- `lib/llm_proxy/protocol.ex` (new)
- `lib/llm_proxy/protocol/openai.ex` (new)
- `lib/llm_proxy/protocol/anthropic.ex` (new)
- `lib/llm_proxy/providers/behaviour.ex` (simplify)
- `lib/llm_proxy/providers/anthropic.ex` (remove conversion, delegate to protocol)
- `lib/llm_proxy/providers/openai.ex` (add `native_protocol/0`)
- `lib/llm_proxy/routes/completion.ex` (new, replaces chat.ex + messages.ex + responses.ex)
- `lib/llm_proxy/router.ex` (update forwards)

Private (`llm_proxy_private`):
- Routes stay as-is (they override public via Dynamic.register)
- Providers stay as-is (they use call_native for passthrough)

---

## Phase 2: Cost Tracking

Both LiteLLM and Langfuse track spend in dollars. We only track token counts.

### Steps

1. **Model pricing data** — extend `mix fetch_models` to pull pricing from models.dev:
   - Store in `priv/models/pricing.json`: `%{model_id => %{input_per_1m, output_per_1m, cache_read_per_1m, cache_write_per_1m}}`
   - Load into `:persistent_term` at startup

2. **Migration** — add `cost_usd` (float) column to `usage_log`

3. **Calculate cost** in `Routes.Helpers.track_usage/3`:
   ```
   cost = (input × price.input_per_1m + output × price.output_per_1m + ...) / 1_000_000
   ```

4. **API key spend** — add `total_spend_usd` to `api_keys`, increment per request

5. **Budget quotas** — add `max_budget_usd` and `budget_period` to `api_keys`. Check in `QuotaCheck` plug. Dollar budgets exist alongside token quotas.

6. **Dashboard** — show $ spend on dashboard, per-key cost column

7. **Private package benefit** — cost tracking works identically for OAuth-based providers since `track_usage` is called from both public and private routes

### Files touched
- `lib/mix/tasks/fetch_models.ex` (pricing fetch)
- `priv/models/pricing.json` (new)
- `lib/llm_proxy/pricing.ex` (new — lookup + calculation)
- `lib/llm_proxy/schemas/usage_log.ex` (add cost_usd)
- `lib/llm_proxy/schemas/api_key.ex` (add total_spend_usd, max_budget_usd)
- `lib/llm_proxy/storage.ex` (budget check queries)
- `lib/llm_proxy/routes/helpers.ex` (cost calculation)
- `lib/llm_proxy/plugs/quota_check.ex` (budget enforcement)
- New migration
- Dashboard LiveView

---

## Phase 3: Latency & Richer Observability

Langfuse's core value prop. We have OTel spans but don't persist or expose them.

### Steps

1. **Migration** — add to `usage_log`:
   - `duration_ms` (integer)
   - `ttft_ms` (integer, nullable — time to first token, streaming only)
   - `provider` (string — which provider actually served the request)

2. **Measure in routes** — wrap provider calls with `System.monotonic_time/1`. For streams, record first chunk timestamp.

3. **Enrich OTel spans** — add duration/ttft as span attributes

4. **Dashboard** — latency columns in recent requests, avg/p50/p95 by model

5. **Time-series stats API**:
   ```
   GET /stats/daily?start_date=2026-03-01&end_date=2026-03-25&group_by=model
   ```
   Returns daily breakdown: requests, tokens, cost, avg latency per group.

### Files touched
- New migration
- `lib/llm_proxy/schemas/usage_log.ex`
- `lib/llm_proxy/routes/completion.ex` (or existing routes)
- `lib/llm_proxy/routes/helpers.ex`
- `lib/llm_proxy/storage.ex` (time-series queries)
- `lib/llm_proxy/routes/stats.ex` (new endpoints)
- Dashboard LiveView

---

## Phase 4: Retry & Fallback

LiteLLM's killer feature. Currently we only cooldown rate-limited tokens — no retries, no fallbacks.

### Steps

1. **Model aliases / groups** — config-driven:
   ```elixir
   config :llm_proxy, :model_aliases, %{
     "gpt-4" => ["openai/gpt-4", "openrouter/openai/gpt-4"]
   }
   ```
   Registry resolves alias → ordered list of provider+model pairs.

2. **Retry logic** in a new `LLMProxy.Providers.Caller` module:
   - On 5xx / timeout / connection error → retry next provider in group
   - Configurable max retries (default 2)
   - On 429 → mark token rate-limited (existing), try next token or provider
   - Exponential backoff between retries

3. **Fallback chains** per model:
   ```elixir
   config :llm_proxy, :fallbacks, %{
     "claude-sonnet-4-20250514" => ["openrouter/anthropic/claude-sonnet-4-20250514"]
   }
   ```

4. **Telemetry on retries** — log which provider failed, which succeeded, attempt count

5. **Private package benefit** — fallbacks from OAuth providers to API-key providers (e.g., Anthropic OAuth rate-limited → fallback to Anthropic API key)

### Files touched
- `lib/llm_proxy/providers/caller.ex` (new — retry/fallback wrapper)
- `lib/llm_proxy/providers/registry.ex` (alias resolution)
- `lib/llm_proxy/config.ex` (alias/fallback config)
- `config/runtime.exs`

---

## Phase 5: Request Metadata & Tags

Both LiteLLM and Langfuse use tags for cost attribution.

### Steps

1. Accept `metadata` in request body:
   ```json
   {"model": "gpt-4", "messages": [...], "metadata": {"tags": ["project:foo"]}}
   ```

2. **Migration** — add `tags` (JSON) and `metadata` (JSON) to `usage_log`

3. **Storage** — filter/group by tags in stats queries

4. **Stats API** — `GET /stats/daily?group_by=tag&tag=project:foo`

5. **Dashboard** — tag filter dropdown

### Files touched
- New migration
- `lib/llm_proxy/schemas/usage_log.ex`
- `lib/llm_proxy/routes/helpers.ex` (extract metadata)
- `lib/llm_proxy/storage.ex`
- `lib/llm_proxy/routes/stats.ex`
- Dashboard LiveView

---

## Phase 6: Full Trace Logging (Langfuse-style)

Currently we store user messages only. For debugging you need full request/response bodies.

### Steps

1. **New table `traces`**:
   - `id`, `key_id`, `model`, `provider`
   - `request_body` (JSON, compressed)
   - `response_body` (JSON, compressed)
   - `input_tokens`, `output_tokens`, `cost_usd`, `duration_ms`, `ttft_ms`
   - `tags`, `metadata`, `session_id` (nullable)
   - `timestamp`

2. **Opt-in per key** — add `trace_requests` boolean to `api_keys`. Only log full bodies when enabled.

3. **Trace viewer in admin UI** — LiveView page with search/filter

4. **Session grouping** — accept `session_id` in metadata, group in UI

5. **Retention** — configurable TTL, background pruning

### Files touched
- New schema + migration
- `lib/llm_proxy/storage.ex`
- `lib/llm_proxy/routes/helpers.ex`
- `lib/llm_proxy/schemas/api_key.ex`
- New LiveView `lib/llm_proxy_web/live/traces_live.ex`

---

## Phase 7: Guardrails (Optional)

### Steps

1. **Define `Guardrail` behaviour**:
   ```elixir
   @callback check_input(body :: map()) :: :ok | {:block, String.t()}
   @callback check_output(response :: map()) :: :ok | {:block, String.t()} | {:mask, map()}
   ```

2. Basic implementations: regex PII detection, keyword blocklist

3. Hook as pluggable pre/post-call in the route pipeline

4. Configurable per key

---

## Implementation Order

| Phase | Effort | Impact | Depends on |
|-------|--------|--------|------------|
| 1. Protocol Abstraction | L | High | — |
| 2. Cost Tracking | M | High | — |
| 3. Latency & Observability | S | High | — |
| 4. Retry & Fallback | M | High | benefits from Phase 1 |
| 5. Request Metadata | S | Medium | benefits from Phase 2 |
| 6. Full Trace Logging | M | Medium | benefits from Phase 3 |
| 7. Guardrails | M | Low | benefits from Phase 1 |

**Recommended order**: 2 → 3 → 1 → 4 → 5 → 6 → 7

- Phase 2 (cost): smallest, highest ROI, no dependencies
- Phase 3 (latency): quick win, independent
- Phase 1 (protocols): largest, architectural foundation for phases 4+
- Phase 4 (retry): most impactful for reliability, benefits from Phase 1
