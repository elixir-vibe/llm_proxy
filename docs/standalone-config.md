# Standalone configuration design

LLMProxy can be used in two different modes:

- **Embedded/library mode** — a host Elixir application depends on `:llm_proxy` and owns ordinary `config :llm_proxy` application config.
- **Standalone proxy mode** — the `llm_proxy` OTP release is the application, deployed and operated as a service.

These modes should share the same internal runtime structures, but they should not share the same operator-facing configuration surface.

## Goals

- Keep embedded app config readable without requiring dependency-provided imports in `config/config.exs`.
- Give standalone operators a product-level config file that does not look like raw Elixir application environment internals.
- Keep secrets separate from routing/provider configuration where practical.
- Preserve existing lower-level `:catalog` and `:providers` config for compatibility.
- Compile all external config forms into the same internal concepts:
  - provider defaults
  - public model aliases
  - catalog deployments
  - token bootstrap/import instructions

## Embedded/library config

Embedded apps should use normal Elixir application config. They should not need to import an LLMProxy helper module in `config/config.exs`, because dependency modules are not a reliable configuration-file surface at compile time.

Recommended embedded shape:

```elixir
config :llm_proxy,
  providers: [
    openai_codex: [base_url: "https://chatgpt.com/backend-api"]
  ],
  models: [
    codex: [route: [to: :openai_codex, model: "gpt-5.3-codex-spark"]],
    fast: [
      routing: :lowest_cost,
      routes: [
        [to: :openai, model: "gpt-4o-mini", timeout: 15_000],
        [to: :anthropic, model: "claude-3-haiku-20240307", order: 2]
      ]
    ]
  ]
```

This shape is normalized by `LLMProxy.Config` into the existing catalog/deployment structures at boot.

## Standalone config files

Standalone configuration should be loaded only by the standalone release. Embedded/library users should not have LLMProxy searching `/etc` or loading release config files unless they explicitly opt in.

Candidate paths:

```text
/etc/llm-proxy/config.toml
/etc/llm-proxy/config.exs
```

Environment overrides, if any, should be limited to locating these files:

```text
LLM_PROXY_CONFIG_DIR=/etc/llm-proxy
LLM_PROXY_CONFIG_TOML=/etc/llm-proxy/config.toml
LLM_PROXY_CONFIG_EXS=/etc/llm-proxy/config.exs
```

### TOML shape

TOML is the normal operator-facing data format.

```toml
[providers.openai-codex]
base_url = "https://chatgpt.com/backend-api"

[[models]]
name = "codex"

[[models.routes]]
to = "openai-codex"
model = "gpt-5.3-codex-spark"

[[models]]
name = "fast"
routing = "lowest_cost"

[[models.routes]]
to = "openai"
model = "gpt-4o-mini"
timeout = 15000

[[models.routes]]
to = "anthropic"
model = "claude-3-haiku-20240307"
order = 2
```

Provider identifiers are strings in standalone data files and resolve through a bundled provider registry. Custom provider modules should not be represented as arbitrary strings unless there is an explicit extension mechanism.

### Trusted Elixir standalone file

If an Elixir config file is supported, it should be a standalone DSL, not `config :llm_proxy` application config.

Possible shape:

```elixir
provider "openai-codex" do
  base_url "https://chatgpt.com/backend-api"
end

model "codex" do
  route "openai-codex", "gpt-5.3-codex-spark"
end

model "fast", routing: :lowest_cost do
  route "openai", "gpt-4o-mini", timeout: 15_000
  route "anthropic", "claude-3-haiku-20240307", order: 2
end
```

This file is trusted code. It should be documented as an expert escape hatch, not the default surface.

## Secrets and token bootstrap

Provider credentials are not the same concern as routing configuration.

Recommended direction:

- Persistent provider tokens live in LLMProxy storage and are managed through admin surfaces.
- Environment token variables remain bootstrap/import compatibility only.
- Standalone config may describe imports, but should not encourage committing secrets to config files.

Possible standalone token import shape:

```toml
[[token_imports]]
provider = "openai-codex"
kind = "oauth"
env = "OPENAI_CODEX_TOKENS"
```

Equivalent trusted Elixir DSL, if added:

```elixir
token_import "openai-codex", kind: "oauth", env: "OPENAI_CODEX_TOKENS"
```

## Loading order

Proposed standalone release loading order:

1. built-in defaults
2. release `runtime.exs`
3. standalone TOML config
4. standalone trusted Elixir config, if present
5. environment secrets/bootstrap imports
6. persisted admin-managed state, where applicable

The exact order should be validated against release boot constraints before implementation.

## Implementation constraints

Before implementation:

- Choose module namespace and source paths deliberately.
- Add tests in mirrored paths only.
- Read `Config.Provider` and any TOML parser docs/source before implementing release-time loading.
- Avoid adding a `Standalone` namespace unless it is accepted as the product concept name.
- Do not add runtime `/etc` loading to embedded/library mode.
- Do not use `String.to_atom/1` on unbounded user/operator data.

## Open questions

- What should the source namespace be for standalone-release config loading?
- Should the trusted Elixir file be supported in the first implementation, or should TOML come first?
- Should standalone config be release `Config.Provider` based, app-start based, or HostKit-generated `runtime.exs` based?
- How should custom third-party provider modules be referenced from standalone data config?
- Should token imports run once, every boot idempotently, or only through an explicit task?
