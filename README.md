# LLM Proxy

Multi-format LLM proxy with usage tracking, per-user quotas, and token pool management. Supports OpenAI Chat Completions, Anthropic Messages, and OpenAI Responses APIs. Built with Elixir, Plug, and SQLite.

## Features

- **OpenAI Chat Completions** (`/v1/chat/completions`) with streaming support
- **Anthropic Messages** (`/v1/messages`) — native passthrough via provider plugins
- **OpenAI Responses** (`/v1/responses`) — native passthrough via provider plugins
- **Provider system** — pluggable providers with model-based routing
- **Token pool** — multiple API keys per provider with FNV-1a hash pinning and 4h rate-limit cooldowns
- **Usage tracking** — per-user input/output/cache token accounting
- **Quota enforcement** — configurable per-key limits
- **API key management** — create, rotate, and revoke keys
- **Service proxies** — Exa search and Context7 docs with shared quota tracking
- **Dynamic route registry** — extend with additional providers and routes

## Bundled Provider

- **OpenRouter** — 343+ models via OpenAI-compatible API

Additional providers can be registered at runtime via `LLMProxy.Providers.Registry` and `LLMProxy.Routes.Dynamic`.

## Setup

```bash
mix setup       # deps.get + create DB + migrate
mix run --no-halt
```

The server starts on port 4000 by default.

## Configuration

Environment variables (or `.env` file):

| Variable | Description |
|---|---|
| `PORT` | Server port (default: `4000`) |
| `MASTER_KEY` | Admin key for setup/management endpoints |
| `DATABASE_PATH` | SQLite database path (default: `./llm_proxy.db`) |
| `OPENROUTER_API_KEYS` | Comma-separated OpenRouter API keys |
| `OPENAI_API_KEYS` | Comma-separated OpenAI API keys |
| `EXA_API_KEY` | Exa search API key |
| `CONTEXT7_API_KEY` | Context7 API key |
| `PUBLIC_URL` | Public URL for key display |

## API

### Proxy

- `POST /v1/chat/completions` — OpenAI Chat Completions (streaming + non-streaming)
- `POST /v1/messages` — Anthropic Messages (requires provider plugin)
- `POST /v1/responses` — OpenAI Responses (requires provider plugin)
- `GET /v1/models`, `GET /models` — list available models
- `GET /health` — health check

### Key Management (requires master key)

- `POST /setup/key` — create API key
- `GET /setup/keys` — list keys
- `DELETE /setup/key/:id` — revoke key
- `PUT /setup/key/:id/quota` — set quota
- `GET /setup/stats` — usage statistics

### Token Management (requires master key)

- `POST /setup/tokens` — add provider token
- `GET /setup/tokens` — list tokens
- `DELETE /setup/tokens/:id` — remove token
- `PUT /setup/tokens/:id/cooldown` — set cooldown
- `GET /setup/tokens/status` — pool status

### Service Proxies

- `POST /v1/exa/*` — Exa search proxy
- `POST /v1/context7/*` — Context7 docs proxy
- `POST /v1/moderations` — OpenAI moderations proxy

## Development

```bash
mix test        # run tests
mix ci          # compile + test + credo + dialyzer + ex_dna
mix format      # format code
```
