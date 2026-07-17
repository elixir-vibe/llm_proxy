# Architecture

LLMProxy is organized around transport adapters, provider execution, and shared core services.

```text
LLMProxy
├── Provider                 # in-process execution boundary for local, HTTP, and ReqLLM calls
├── HTTP
│   ├── Router               # standalone Plug router
│   └── Routes               # thin HTTP endpoint adapters
├── Phoenix
│   └── Router               # Phoenix forwarding macros for host apps
├── Providers
│   ├── Registry             # provider/model lookup and catalog resolution
│   ├── Caller               # attempts, fallback, timeout, retry, rate-limit handling
│   ├── CircuitBreaker       # deployment health state
│   └── Routing              # deployment ordering strategies
├── Protocol                 # OpenAI/Anthropic request and response normalization
├── Cache                    # adapter behaviour, key, policy, runtime
├── Accounting               # usage, spend, trace/message recording
├── Auth                     # non-Plug access decisions
├── TokenPool                # token selection and token cooldown state
├── Catalog                  # public model aliases and deployments
├── ReqLLM                   # ReqLLM adapters/helpers
├── Stream                   # transport-neutral stream event/SSE helpers
├── Admin                    # Incant admin resources, dashboards, and policy
└── Schemas / Storage        # persistence boundary
```

Rules of thumb:

- HTTP modules parse/render only; core execution belongs in `LLMProxy.Provider` or `LLMProxy.Providers.*`.
- Phoenix embedding helpers live under `LLMProxy.Phoenix`; the root `LLMProxy.Router` is only a public facade.
- Provider deployment selection belongs under `LLMProxy.Providers.Routing`, not HTTP routing.
- Adapter behaviours use singular module names (`Cache`); runtime dispatch belongs in explicit submodules (`Cache.Runtime`).
- `LLMProxy.Storage` is a facade over `config :llm_proxy, storage: ...`; the default `LLMProxy.Storage.Ecto` implementation goes through `LLMProxy.Storage.Repo`, which delegates to `config :llm_proxy, repo: MyApp.Repo`. DB-specific SQL and migrations branch on the configured repo's `__adapter__/0`, and database adapters remain host-provided/optional.
- `LLMProxy.Admin` is the only service-owned admin surface. It exposes Ecto schemas convention-first through Incant, while modules under `LLMProxy.Admin.Resources.*` override inferred resources automatically. Do not add a parallel public admin UI or public service-owned admin HTTP routes.
- Provider-specific defaults live in nested provider config (`config :llm_proxy, providers: ...`). Named providers with an `adapter` are executed by `LLMProxy.Providers.ReqLLM`; endpoint/model differences do not require new LLMProxy modules.
- Catalog deployments carry `provider_name` and `token_pool` into execution attempts. This keeps credentials isolated when multiple named services share one ReqLLM adapter.
