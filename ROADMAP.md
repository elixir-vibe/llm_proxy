# Roadmap

LLMProxy is an Elixir-native gateway that can run inside an application or as a standalone service. The project favors a focused execution and governance layer over a broad hosted AI platform.

## Product boundary

In scope:

- in-process, ReqLLM, SafeRPC, and HTTP execution through one provider boundary;
- OpenAI and Anthropic protocol compatibility where clients need it;
- public model aliases, provider routing, fallback, and circuit breakers;
- API keys, model access, budgets, quotas, token pools, usage, cost, and traces;
- deterministic cache and guardrail extension points;
- service-owned admin surfaces through optional Incant integration;
- local ownership of configuration and operational data.

Out of scope for the core package:

- a hosted prompt-management or evaluation product;
- bundled SSO, organization, or billing systems;
- a general non-LLM reverse proxy;
- provider-specific modules for services already supported through ReqLLM configuration;
- semantic caching or a bundled policy engine;
- MCP and agent gateway features without a concrete Elixir integration need.

## Current priorities

### Governance

- Add per-model and future actor/team budget scopes without weakening the existing API-key boundary.
- Add RPM and TPM limits to the composable limit model.
- Improve cache-hit accounting and policy visibility.

### Routing

- Improve the latency-aware strategy with operator-visible route eligibility and measurements.
- Add least-busy routing when enough runtime measurements exist to make it predictable.
- Improve operator visibility into cooldowns and circuit state.
- Keep provider credentials isolated as routing configurations grow.

### Observability

- Extend spans around cache and guardrail hooks.
- Add export hooks for external analytics without making them storage dependencies.
- Improve feedback and trace workflows through the optional admin surface.

### Operations

- Keep standalone TOML intentionally narrow and secret-free.
- Improve release migration, backup, restore, and drain ergonomics.
- Preserve library mode as the default architectural constraint: no feature should require a network hop when an application embeds LLMProxy.
