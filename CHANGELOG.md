# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-07-20

First public release.

LLMProxy is an embeddable Elixir/Phoenix LLM gateway with usage tracking,
quotas, provider token pools, and OpenAI-compatible HTTP routes.

### Execution and routing

- In-process execution boundary via `LLMProxy.Provider` and `LLMProxy.chat/2`.
- ReqLLM provider registered as `:llm_proxy`, including remote BEAM calls.
- Model catalog with aliases, ordered/shuffled deployments, per-deployment
  timeouts, and circuit breakers.
- Retries and fallback across providers and models.
- Direct providers for OpenAI, Anthropic, OpenRouter, OpenAI Codex, and Kimi
  Code, plus an OpenAI-compatible provider helper for custom upstreams.
- Reasoning effort levels forwarded to models that support them.

### HTTP API

- OpenAI Chat Completions (`/v1/chat/completions`) with streaming.
- Anthropic Messages (`/v1/messages`) with streaming.
- OpenAI Responses (`/v1/responses`) with streaming.
- OpenAI Moderations (`/v1/moderations`).
- Streaming hardening: heartbeats during upstream silence, bounded connection
  capacity, and terminal-failure classification.
- Configurable request body limit with authentication before body parsing.

### Governance

- API key management with per-key quotas (tokens, messages, cache) and
  composable budget limits.
- Provider token pools with stable user pinning and `Retry-After` cooldowns.
- Usage tracking for input/output/cache tokens and estimated cost in USD.
- Request metadata and tags for cost attribution.
- Full trace logging with request/response bodies, latency, and feedback API.

### Extension points

- Guardrail hooks for request/response/stream policy without a bundled policy
  engine.
- Deterministic cache hooks for pluggable non-stream response caching.
- Embeddable storage migrations with SQLite and DuckDB (QuackDB) adapters.

### Admin and operations

- Incant admin surfaces for API keys, provider tokens, traces, and messages,
  plus an operations dashboard.
- OpenTelemetry instrumentation (HTTP, Ecto, Req).
- Drain support for graceful deploys.

[Unreleased]: https://github.com/elixir-vibe/llm_proxy/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/elixir-vibe/llm_proxy/releases/tag/v0.1.0
