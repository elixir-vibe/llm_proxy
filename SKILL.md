---
name: llm-proxy
description: Configure, embed, operate, and extend LLMProxy as an Elixir/ReqLLM gateway with model aliases, isolated provider token pools, accounting, streaming, tools, SafeRPC, and OpenAI-compatible HTTP routes.
---

# LLMProxy

Use this skill when adding an upstream model/service, changing provider routing, embedding LLMProxy, configuring the standalone release, provisioning provider credentials, or debugging requests through LLMProxy.

## Core rule

Prefer data configuration and ReqLLM over provider-specific LLMProxy code.

For a service that differs only by endpoint, credential pool, or model ID:

1. Declare a named provider with a ReqLLM `adapter`.
2. Set its `base_url` and isolated `token_pool`.
3. Add a public model alias with an upstream route.
4. Provision credentials into that token pool without committing them.
5. Verify non-streaming, streaming, reasoning, tools, and usage.

Do not add a new LLMProxy provider module for an OpenAI-compatible base URL or model alias. Add provider code only when ReqLLM does not support the authentication or wire protocol; prefer contributing reusable support to ReqLLM first.

## Configuration-driven provider

Embedded Elixir configuration:

```elixir
config :llm_proxy,
  providers: %{
    "example-service" => %{
      adapter: "openai",
      base_url: "https://api.example.com/v1",
      token_pool: "example-production"
    }
  },
  models: [
    [
      name: "example/model",
      routes: [[to: "example-service", model: "upstream-model"]]
    ]
  ]
```

Standalone TOML:

```toml
[providers.example-service]
adapter = "openai"
base_url = "https://api.example.com/v1"
token_pool = "example-production"

[[models]]
name = "example/model"

[[models.routes]]
to = "example-service"
model = "upstream-model"
```

Rules:

- `adapter` must be an existing ReqLLM provider ID. Inspect `ReqLLM.Providers.list/0` rather than guessing.
- `token_pool` defaults at provider level and may be overridden per route.
- A provider token belongs to a pool when its `provider` field equals the pool name.
- A token's optional `proxy` overrides the provider base URL for that token only.
- Keep public aliases distinct when multiple upstreams expose colliding model IDs.
- Configuration-driven providers currently use LLMProxy's normalized chat path. Native Messages/Responses passthrough requires explicit native support.

## Credentials

Never commit API keys, OAuth tokens, secret environment files, logs containing credentials, or copied admin payloads.

Standalone releases may bootstrap arbitrary API-key pools with:

```text
LLM_PROXY_PROVIDER_KEYS={"example-production":["secret-key"]}
```

This is secret runtime state, not TOML content. Persisted `provider_tokens` are the runtime source after seeding and are included when the configured LLMProxy storage is backed up.

Before using a user-supplied key:

- identify which product issued it;
- use that product's official endpoint;
- do not silently substitute OpenRouter or another aggregator;
- avoid printing the key during validation;
- recommend rotation if it was exposed in chat, logs, or shell history.

## Routing and token isolation

A public model resolves to one or more catalog deployments. Each deployment carries:

- named provider identity;
- upstream model ID;
- token pool;
- timeout and circuit-breaker settings;
- optional order/weight metadata.

Do not collapse token pools that use the same ReqLLM adapter. For example, an OpenAI key and a Kimi Code key may both use adapter `openai`, but they must have separate named providers and pools so credentials can never cross endpoints.

## Verification

For every newly configured service, test all capabilities the intended client will use:

1. Authenticated direct upstream smoke test.
2. LLMProxy non-streaming request through the public alias.
3. Streaming request with text and final usage.
4. Reasoning deltas/content when the model reasons.
5. Strict function-tool request and returned tool call.
6. `/v1/models` contains the intended alias and no accidental raw/colliding alias.
7. Usage and provider/token-pool identity are recorded correctly.
8. Invalid or unavailable credentials fail without falling through to another pool.

Run the project gate after code changes:

```bash
env MIX_HOME=$HOME/.mix MIX_ARCHIVES=$HOME/.mix/archives mix ci
env MIX_HOME=$HOME/.mix MIX_ARCHIVES=$HOME/.mix/archives mix hex.audit
```

Treat advisories according to the repository's documented security policy; do not silently suppress them.

## Deployment safety

In a HostKit-managed installation:

- identify local versus server execution context explicitly;
- modify tracked HostKit source, not generated live configuration;
- commit and push LLMProxy and infrastructure changes before deployment;
- plan the smallest relevant service set before apply;
- apply through HostKit with tracking;
- verify health, logs, restart count, model catalog, completion, streaming, tools, and post-apply convergence.

Read the consuming repository's `AGENTS.md` and disaster-recovery documentation before deployment.

## References

- `README.md` — embedding, HTTP API, catalog, and runtime overview
- `docs/providers.md` — configured providers, token pools, OAuth, and custom protocols
- `docs/architecture.md` — execution boundaries
- `docs/roadmap.md` — current limitations and remaining work
