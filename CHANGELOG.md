# Changelog

## Unreleased

### Breaking Changes

- Standalone non-secret runtime settings now come from TOML instead of
  environment variables. `PORT`, `PUBLIC_URL`, `DATABASE_PATH`, `QUACKDB_URI`,
  `QUACKDB_ENDPOINT`, `LLM_PROXY_RPC_SOCKET`, `LLM_PROXY_BODY_LIMIT_BYTES`,
  `LLM_PROXY_PROVIDER_CONNECT_TIMEOUT_MS`, `LLM_MAX_RETRIES`,
  `LLM_FALLBACKS`, and `OTEL_EXPORTER_OTLP_ENDPOINT` are no longer read.
  Configure the corresponding `[server]`, `[storage]`, `[routing]`,
  `[telemetry]`, provider, and model-route settings in the standalone TOML file.
- Standalone `OPENAI_API_KEYS`, `ANTHROPIC_API_KEYS`, `OPENROUTER_API_KEYS`, and
  `OPENAI_CODEX_TOKENS` bootstrapping has been removed. Seed API-key pools with
  the secret `LLM_PROXY_PROVIDER_KEYS` JSON object. Provision Codex OAuth through
  the admin login flow and preserve its stored token rows in backups.
- Standalone TOML is now strict and rejects unknown sections, unknown keys, and
  provider credentials. Library mode remains configured through ordinary Elixir
  application configuration and may source secrets however the host chooses.

### Added

- Token selection now skips accounts only while fresh provider-usage snapshots
  prove exhaustion, waits for every exhausted window to reset, and persists
  account- or model-scoped rate-limit cooldowns across restarts without storing
  raw model IDs.
- A supervised provider-usage tracker now reports each configured OpenAI Codex
  or GLM Coding Plan account separately. The optional Incant admin surface shows
  live upstream windows, availability, reset times, freshness, and safe errors,
  with bounded automatic refresh and manual refresh actions. Provider payloads
  use strict JSONCodec boundaries, response sizes are capped, and malformed or
  out-of-scope refresh results fail atomically.
- Provider-token pools support affinity or fill-first selection. Fill-first
  orders healthy tokens within the existing OAuth-first/API-key-fallback
  boundary by persisted non-negative priority and stable token ID.
- An optional public-model allowlist keeps HTTP discovery, setup helpers,
  SafeRPC status, and request admission aligned. Standalone deployments
  configure visible aliases through `catalog.public_models` in strict TOML;
  library hosts use normal application configuration.
- API keys can be disabled and re-enabled without deleting their limits, usage,
  or audit history. Disabled keys receive the normal invalid-key response.
- Provider API keys and OAuth tokens can use a pluggable at-rest codec with a
  versioned AES-256-GCM keyring, explicit migration, verification, rotation,
  and controlled plaintext rollback tasks.
- API keys can now set an in-memory concurrent-request limit with stream-safe,
  process-monitored leases across in-process, ReqLLM, SafeRPC, and HTTP
  generation or moderation calls.
- API keys now expose an explicit `capture_content` policy for message, trace-body,
  and deterministic response-cache storage.

### Changed

- Content capture is disabled by default for new API keys. Usage, cost, latency,
  and content-free trace metadata remain available, while message extraction,
  trace-body serialization, and cache access require explicit capture consent.
- Provider fallback now has a strict attempt budget and replays only proven-safe failures by default. Timeouts and 5xx responses require the explicit `:allow_uncertain` compatibility policy, and visible streams are never replayed.

### Security

- Provider-token encryption uses a keyring separate from the API master key,
  creates redacted request-scoped credentials only after token selection, and
  fails closed when an encrypted credential is selected without its keyring.
- Sensitive Incant fields are redacted before local rendering or remote SafeRPC
  transport.

### Migration

- Existing provider tokens receive priority `0`; indexed DuckDB tables rebuild
  the provider/kind index while adding or removing the priority column.
- Existing API keys remain enabled when lifecycle state is added.
- Existing trace-enabled keys retain content capture. Other existing keys stop
  automatic message and cache capture after migration. Operators must define
  retention and remove content stored before this change according to policy.

## 0.1.1 - 2026-08-01

### Fixed

- Streaming endpoints now wait for the first upstream event before committing HTTP 200, return immediate lazy-stream failures as HTTP errors, and render sanitized protocol error events when providers fail after streaming begins.
- OpenAI Codex stream failures now preserve safe upstream reasons, while trace-correlated diagnostics distinguish upstream failures from local storage errors without exposing request, query, or credential data.
- Token counters now use 64-bit database columns, and accounting exceptions are reported internally without turning a completed model stream into a client failure.
- OpenAI-compatible provider failures now return one normalized error object, forwarding structured upstream fields without duplicate `details.error` wrappers or inspected Elixir terms.
- Public HTTP and SSE errors now use protocol-native OpenAI or Anthropic envelopes across authentication, quotas, JSON parsing, draining, guardrails, moderation, routing, and provider failures; only bounded safe fields reach clients.
- Release deployment drains now work from clean release-eval VMs, advertise their bounded SafeRPC atom vocabulary, and restore request acceptance when a drain deadline expires.
- OpenAI Codex WebSockets now use a finite connection deadline with no default established-stream receive deadline, and timeout or handshake failures retain safe phase/status diagnostics.
- Named tool choices and function tool definitions now normalize across OpenAI Chat, OpenAI Responses, and Anthropic Messages routing boundaries.
- ReqLLM now uses the released Hex package at v1.18, replacing the temporary Git pin; Cowboy/Cowlib were updated to versions that resolve the newly published memory-exhaustion advisories.

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
