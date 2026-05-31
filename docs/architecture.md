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
├── Web                      # bundled Phoenix admin UI
└── Schemas / Storage        # persistence boundary
```

Rules of thumb:

- HTTP modules parse/render only; core execution belongs in `LLMProxy.Provider` or `LLMProxy.Providers.*`.
- Phoenix embedding helpers live under `LLMProxy.Phoenix`; the root `LLMProxy.Router` is only a public facade.
- Provider deployment selection belongs under `LLMProxy.Providers.Routing`, not HTTP routing.
- Adapter behaviours use singular module names (`Cache`); runtime dispatch belongs in explicit submodules (`Cache.Runtime`).
- Provider-specific defaults live in nested provider config (`config :llm_proxy, providers: ...`).
