# Changelog

## Unreleased

### Fixed

- Streaming endpoints now wait for the first upstream event before committing HTTP 200, return immediate lazy-stream failures as HTTP errors, and render sanitized protocol error events when providers fail after streaming begins.
- OpenAI Codex stream failures now preserve safe upstream reasons, while trace-correlated diagnostics distinguish upstream failures from local storage errors without exposing request, query, or credential data.
- Token counters now use 64-bit database columns, and accounting exceptions are reported internally without turning a completed model stream into a client failure.

### Security

- Require SafeRPC 0.1.15 or later for bounded frames, strict request validation, executable ETF rejection, and isolated listener failures.

## 0.1.0 - 2026-07-22

### Added

- In-process execution through `LLMProxy.Provider` and `LLMProxy.chat/2`.
- ReqLLM provider registration as `:llm_proxy`, including remote BEAM calls.
- Model catalog with aliases, ordered or shuffled deployments, per-deployment
  timeouts, circuit breakers, retries, and fallback across providers and models.
- Direct providers for OpenAI, Anthropic, OpenRouter, OpenAI Codex, and Kimi
  Code, plus an OpenAI-compatible provider helper for custom upstreams.
- Reasoning effort levels forwarded to models that support them.
- OpenAI Chat Completions (`/v1/chat/completions`) with streaming.
- Anthropic Messages (`/v1/messages`) with streaming.
- OpenAI Responses (`/v1/responses`) with streaming.
- OpenAI Moderations (`/v1/moderations`).
- Streaming heartbeats during upstream silence, bounded connection capacity,
  and terminal-failure classification.
- Configurable request body limits with authentication before body parsing.
- API key management with per-key token, message, and cache quotas plus
  composable budget limits.
- Provider token pools with stable user pinning and `Retry-After` cooldowns.
- Usage tracking for input, output, and cache tokens plus estimated USD cost.
- Request metadata and tags for cost attribution.
- Trace logging with request and response bodies, latency, and a feedback API.
- Guardrail hooks for request, response, and stream policy without a bundled
  policy engine.
- Deterministic cache hooks for pluggable non-stream response caching.
- Embeddable storage migrations with SQLite and DuckDB (QuackDB) adapters.
- Optional Incant admin surfaces for API keys, provider tokens, traces, and
  messages, plus an operations dashboard.
- OpenTelemetry instrumentation for HTTP, Ecto, and Req.
- Drain support for graceful deployments.

### Compatibility

- Requires Elixir 1.17 or later.
- Incant integration is optional and supports Incant 0.1.x.
