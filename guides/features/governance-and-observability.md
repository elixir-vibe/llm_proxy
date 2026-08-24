# Governance and Observability

LLMProxy applies authentication, model access, limits, accounting, and tracing at the provider execution boundary. In-process, ReqLLM, [SafeRPC](https://hexdocs.pm/safe_rpc), and HTTP callers therefore receive the same controls.

## API keys

Create an application key through the storage facade:

```elixir
{:ok, api_key, raw_key} =
  LLMProxy.Storage.create_key("production-worker", %{
    allowed_models: ["fast", "coding"]
  })
```

`raw_key` is returned once. LLMProxy stores its hash and looks up the record for later requests. Deliver the raw key through your normal secret-management channel.

HTTP clients authenticate with either header:

```text
Authorization: Bearer sk-proxy-...
x-api-key: sk-proxy-...
```

In-process callers pass the raw key, an API-key schema/map, or `%LLMProxy.Actor{}`.

The configured master key represents operator access. It bypasses ordinary model and quota checks and should be reserved for bootstrap, administration, and trusted service operations.

## Model access

Set `allowed_models` on an API key to constrain it to public catalog names:

```elixir
%{
  allowed_models: ["fast", "coding"]
}
```

Clients never need direct access to upstream provider names or credentials. Catalog aliases are the policy boundary.

## Composable limits

Most composable limits operate over stored usage windows. A concurrent-request
limit is an in-memory admission limit and does not use a window:

```elixir
%{
  budget_limits: [
    LLMProxy.Limit.cost(:day, 10.00),
    LLMProxy.Limit.requests(:minute, 60),
    LLMProxy.Limit.input_tokens(:four_hours, 100_000),
    LLMProxy.Limit.output_tokens(:week, 500_000),
    LLMProxy.Limit.concurrent_requests(8)
  ]
}
```

Supported metrics:

- `:cost_usd`
- `:requests`
- `:input_tokens`
- `:output_tokens`
- `:cache_read_tokens`
- `:cache_write_tokens`
- `:concurrent_requests`

Supported windows:

- `:minute`
- `:hour`
- `:four_hours`
- `:day`
- `:week`
- `:month`

`concurrent_requests` has no window. It limits active generation and moderation
calls for one API key in one LLMProxy runtime instance. A rejected call receives
HTTP 429 and `Retry-After: 1` on HTTP routes. A stream keeps its slot until it
completes, halts, raises, or its consumer process exits.

Admission and release do not query storage. Aggregate content-free counters are
available from `LLMProxy.ConcurrencyLimiter.status/0` and the standalone health
response. `LLMProxy.ConcurrencyLimiter.status/1` returns the active count for a
key without a storage query.

When several LLMProxy instances serve the same keys, the limit applies to each
instance. Set the per-instance value to match the total capacity plan.

Stored maps may use equivalent strings such as `"cost_usd"`, `"4h"`, `"24h"`, `"7d"`, and `"30d"`.

Existing fixed quota fields remain supported for four-hour and weekly token/message limits. New integrations should prefer `budget_limits` when they need several metrics or windows.

## Usage and cost

Successful requests record:

- input and output tokens;
- cache read and write tokens;
- estimated USD cost from LLMDB pricing;
- provider and upstream model;
- request duration and time to first token when available;
- public model, tags, metadata, and trace ID;
- the API key and optional message record responsible for the call.

`LLMProxy.Response` exposes usage and routing information to in-process callers:

```elixir
response.usage
response.provider_name
response.model
response.trace_id
response.cache_hit
```

HTTP wire responses retain their protocol shape. The trace ID is returned through `x-request-id` and `x-llm-proxy-trace-id` headers.

## Traces and messages

Content capture is disabled for new API keys. Usage, cost, model, provider, latency, tags, metadata, and trace identifiers remain available when content capture is off.

Set `capture_content: true` only on keys allowed to retain prompts and model output. This enables user-message records and deterministic response caching. Set `trace_requests: true` as well when you need trace records. A trace remains content-free unless both settings are true.

```elixir
{:ok, key, _raw_key} =
  LLMProxy.Storage.create_key("debug-worker", %{
    capture_content: true,
    trace_requests: true
  })

{:ok, key} = LLMProxy.Storage.set_content_capture(key.id, false)
```

The setting controls new message and trace-body writes as well as cache reads and writes. Disabling it does not remove content already stored by a message, trace, or external cache adapter; apply each storage owner's retention policy separately.

Existing installations get the following migration behavior:

- Existing keys with `trace_requests: true` keep content capture enabled. This preserves their explicit full-trace behavior.
- All other existing keys get `capture_content: false`. Their automatic user-message capture stops after migration.
- New keys get `capture_content: false` unless an operator enables it.

LLMProxy does not apply an automatic content-retention period. Define a retention period for your deployment. Delete expired message rows and trace bodies through the storage owner. Deleting an API key through `LLMProxy.Storage.delete_key/1` deletes its messages, traces, feedback, and usage rows in one transaction.

The optional Incant message table marks captured text as sensitive. Local table/detail models and remote SafeRPC results contain only a redacted value. Direct storage access to messages and trace details is an approved-content path and must use operator authorization.

Before enabling body tracing:

- define retention and deletion policy;
- restrict access to trace storage and admin surfaces;
- avoid tracing keys that carry secrets or regulated data unless storage controls permit it;
- understand that metadata and tags may also contain user-defined values.

Message logs and traces share request identifiers so authorized operators can move from aggregate usage to an individual call.

## Feedback

Submit feedback by `request_id` or `trace_id` through:

```text
POST /feedback
POST /v1/feedback
```

The feedback record links to the stored trace and API key. Use it for operator review or downstream evaluation systems; LLMProxy does not bundle a hosted evaluation product.

## Telemetry events

LLMProxy emits `:telemetry` events for routing attempts and circuit-breaker transitions.

Routing event prefixes include:

```elixir
[:llm_proxy, :routing, :attempt, :start]
[:llm_proxy, :routing, :attempt, :stop]
[:llm_proxy, :routing, :attempt, :exception]
[:llm_proxy, :routing, :attempt, :skip]
[:llm_proxy, :routing, :stream_attempt, :start]
```

Circuit event prefixes include:

```elixir
[:llm_proxy, :circuit, :open]
[:llm_proxy, :circuit, :half_open]
[:llm_proxy, :circuit, :closed]
[:llm_proxy, :circuit, :skip]
```

Metadata identifies provider, upstream model, and timeout. Stop and exception events add result-specific measurements or metadata.

Attempt events also include `attempt_number`, `max_attempts`, and `replay_policy`. Failure and route-skip events add `replay_safety`, `replay_decision`, and `replay_reason`. Skip reasons distinguish open circuits from unsupported native protocols without consuming the attempt budget. These values are bounded routing labels and do not include request or response content.

## OpenTelemetry

Provider execution creates spans named by operation, such as:

```text
llm_proxy.provider.call
llm_proxy.provider.stream
```

Spans include provider and model attributes plus the LLMProxy trace ID. HTTP, Ecto, and Req integrations are instrumented through their OpenTelemetry packages.

Standalone releases enable OTLP export when `OTEL_EXPORTER_OTLP_ENDPOINT` is set. Without it, trace export is disabled.

## Operational admin

The optional Incant integration presents API keys, provider tokens, traces, messages, and an operations dashboard without making Incant a runtime requirement for the gateway.

See [Admin Integration](admin-integration.md) for topology and access boundaries.
