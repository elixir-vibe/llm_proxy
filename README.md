# LLM Proxy

Embeddable Elixir/Phoenix LLM gateway with usage tracking, quotas, provider token pools, and OpenAI-compatible HTTP routes.

`LLMProxy.Provider` is the primary in-process execution boundary. HTTP routing is a thin adapter around it, so Phoenix apps can use the same accounting, fallback, and provider dispatch without localhost HTTP calls.

## What it provides

- **In-process Elixir API** via `LLMProxy.Provider` and `LLMProxy.chat/2`
- **ReqLLM provider** registered as `:llm_proxy`
- **Phoenix/Plug HTTP API** for OpenAI-compatible clients
- **OpenAI Chat Completions** (`/v1/chat/completions`) with streaming support
- **Anthropic Messages** (`/v1/messages`) with streaming support
- **OpenAI Responses** (`/v1/responses`) with streaming support
- **OpenAI Moderations** (`/v1/moderations`)
- **Provider system** with model-based dispatch, retries, and fallback models
- **Token pool** with multiple upstream API keys, stable user pinning, and cooldowns
- **Usage tracking** for input/output/cache tokens and estimated cost
- **Quota enforcement** with per-key token/message/cache controls
- **API key and provider token management**
- **Admin LiveView UI** for keys, tokens, usage, traces, messages, and models

## Architecture

```text
Local Elixir calls       ReqLLM calls           HTTP clients
LLMProxy.chat/2          provider: :llm_proxy   /v1/chat/completions
       │                       │                       │
       └──────────────┬────────┴──────────────┬────────┘
                      ▼                       ▼
              LLMProxy.Provider        HTTP route adapters
                      │
                      ▼
       provider resolution / quota / fallback / usage / tracing
                      │
                      ▼
             OpenAI / Anthropic / OpenRouter
```

Core request contracts use `ReqLLM.Context` and `ReqLLM.Message` internally. Wire maps stay at HTTP/provider boundaries.

## Local Elixir usage

```elixir
{:ok, response} =
  LLMProxy.chat("Explain GenServers briefly",
    model: "openai/gpt-4.1-mini",
    api_key: raw_or_loaded_llm_proxy_key
  )

response.body
response.usage
```

## ReqLLM usage

```elixir
model = %{
  provider: :llm_proxy,
  id: "openai/gpt-4.1-mini",
  model: "openai/gpt-4.1-mini"
}

{:ok, response} =
  ReqLLM.Generation.generate_text(model, "Hello",
    api_key: raw_llm_proxy_key
  )

ReqLLM.Response.text(response)
```

## Phoenix embedding

Mount core LLM routes in a host Phoenix router:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  use LLMProxy.Router

  scope "/" do
    pipe_through :api

    llm_proxy "/llm", admin: false, setup: false
  end
end
```

Route groups:

- `core: true` — models, chat, messages, responses, moderations
- `admin: true` — keys, tokens, stats/admin
- `setup: true` — optional setup helper routes; disabled by default

## Standalone HTTP API

`LLMProxy.Router` can also be run as the app router.

### Core routes

- `GET /health`
- `GET /v1/models`
- `GET /models`
- `POST /v1/chat/completions`
- `POST /chat/completions`
- `POST /v1/messages`
- `POST /v1/responses`
- `POST /v1/moderations`
- `POST /moderations`

### Admin routes

Require the master key.

- `GET /keys`
- `POST /keys/generate`
- `GET /keys/:id`
- `POST /keys/quota`
- `DELETE /keys/:id`
- `GET /keys/usage` — self-service usage for the current key
- `GET /tokens`
- `POST /tokens`
- `PATCH /tokens/:id`
- `DELETE /tokens/:id`
- `POST /tokens/clear-rate-limits`
- `GET /stats`
- `GET /stats/daily`
- `GET /stats/messages`

`/admin` is an alias for stats.

### Optional setup routes

`/setup` is not mounted by default in embeddable router usage. It exists for local/onboarding helper flows such as install script, model listing, and client config snippets.

## Bundled providers

- **OpenAI** — GPT/o-series models via standard API key
- **Anthropic** — Claude models via standard API key
- **OpenRouter** — OpenRouter models via OpenAI-compatible API

Additional upstream providers can be registered with `LLMProxy.Providers.Registry`.

## Configuration

Environment variables can be loaded from `.env` through Dotenvy.

| Variable | Description |
|---|---|
| `PORT` | Server port in prod, default `4000` |
| `MASTER_KEY` | Admin key |
| `DATABASE_PATH` | SQLite database path in prod, default `./llm_proxy.db` |
| `PUBLIC_URL` | Public base URL used by setup helpers and provider headers |
| `OPENAI_API_KEYS` | Comma-separated OpenAI API keys |
| `ANTHROPIC_API_KEYS` | Comma-separated Anthropic API keys |
| `OPENROUTER_API_KEYS` | Comma-separated OpenRouter API keys |
| `LLM_FALLBACKS` | JSON map of model fallback chains |
| `LLM_MAX_RETRIES` | Number of fallback models to try, default `1` |

## Setup

```bash
mix setup
mix run --no-halt
```

## Development

```bash
mix test
mix ci
mix format
```

Test files mirror source structure under `test/llm_proxy/**`.

## Direction

LLMProxy intentionally focuses on a smaller surface than LiteLLM or Portkey:

- embeddable in Phoenix apps
- Elixir/ReqLLM-native execution
- HTTP compatibility where useful
- strict internal contracts
- local ownership of usage and quota data

Planned gateway features are tracked in `docs/roadmap.md`.
