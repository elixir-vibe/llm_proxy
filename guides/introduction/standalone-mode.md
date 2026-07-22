# Standalone Mode

Standalone mode runs LLMProxy as its own OTP service. It owns the HTTP listener, provider token pools, catalog, accounting data, and DuckDB-backed storage. Elixir applications, command-line tools, and OpenAI-compatible clients can share one gateway.

Use this mode when several callers need centralized model routing and governance, or when the gateway should deploy independently from the applications that consume it.

## Runtime shape

The production release starts:

- a Cowboy listener bound to `127.0.0.1`;
- the LLMProxy provider registry and model catalog;
- routing, circuit-breaker, drain, and token-pool processes;
- a managed local QuackDB server over DuckDB storage;
- an optional [SafeRPC](https://hexdocs.pm/safe_rpc) Unix socket;
- OpenTelemetry instrumentation when an OTLP endpoint is configured.

The loopback bind is intentional. Put a reverse proxy, ingress, or service mesh in front of LLMProxy when serving other hosts.

## Secrets and runtime values

Set secrets in the service environment:

```bash
MASTER_KEY="replace-with-a-long-random-key"
OPENAI_API_KEYS="sk-primary,sk-secondary"
ANTHROPIC_API_KEYS="sk-ant-..."
OPENROUTER_API_KEYS="sk-or-..."
DATABASE_PATH="/var/lib/llm-proxy/llm_proxy.duckdb"
PORT="4000"
PUBLIC_URL="https://llm.example.com"
```

`MASTER_KEY` is the bootstrap and operator credential. Provider-key variables seed persisted token records at startup. Existing records remain the runtime source after seeding.

For named configuration-driven providers, seed isolated token pools with JSON:

```bash
LLM_PROXY_PROVIDER_KEYS='{"example-production":["secret-key"]}'
```

Never put API keys, OAuth tokens, or proxy credentials in TOML.

## Data configuration

The release optionally reads `/etc/llm-proxy/config.toml`. Override that path with `LLM_PROXY_CONFIG_TOML`.

```toml
[providers.example-service]
adapter = "openai"
base_url = "https://api.example.com/v1"
token_pool = "example-production"

[[models]]
name = "coding"
routing = "ordered"

[[models.routes]]
to = "example-service"
model = "upstream-coding-model"
timeout = 30000
failure_threshold = 3
cooldown_ms = 30000
```

The TOML loader accepts provider and model data only. Secrets remain in environment variables or persisted provider-token storage. If the file is absent, startup continues with environment and compiled configuration.

See [Providers and Routing](../features/providers-and-routing.md) for the complete model shape.

## Storage

Production uses `LLMProxy.Storage.Repo.QuackDB` and a managed QuackDB process backed by the file at `DATABASE_PATH`.

Related settings:

| Variable | Default | Purpose |
|---|---|---|
| `DATABASE_PATH` | `./llm_proxy.duckdb` | DuckDB database file |
| `QUACKDB_URI` | `http://127.0.0.1:9494` | Ecto adapter endpoint |
| `QUACKDB_ENDPOINT` | `quack:localhost:9494` | Managed QuackDB listener |

Run migrations before starting a new release:

```bash
bin/llm_proxy eval 'LLMProxy.ReleaseTasks.migrate()'
```

The task starts only the storage dependencies it needs, applies all bundled migrations, and checkpoints DuckDB before returning.

## HTTP API

Core routes are enabled in standalone mode:

```text
GET  /health
GET  /v1/models
POST /v1/chat/completions
POST /v1/messages
POST /v1/responses
POST /v1/moderations
POST /v1/feedback
```

Generation, moderation, and feedback requests accept either:

```text
Authorization: Bearer <llm-proxy-key>
x-api-key: <llm-proxy-key>
```

Example:

```bash
curl http://127.0.0.1:4000/v1/chat/completions \
  -H "authorization: Bearer $MASTER_KEY" \
  -H "content-type: application/json" \
  -d '{
    "model": "coding",
    "messages": [{"role": "user", "content": "Write a GenServer outline"}],
    "stream": false
  }'
```

The default authenticated JSON body limit is 32 MB. Set `LLM_PROXY_BODY_LIMIT_BYTES` to a positive integer to change it. Authentication and quota checks run before the body is read and decoded.

Streaming endpoints emit SSE comment heartbeats while an upstream stream is silent. Heartbeats keep connections alive without changing OpenAI or Anthropic event payloads.

## SafeRPC and admin

Set a Unix socket path to start the SafeRPC server:

```bash
LLM_PROXY_RPC_SOCKET="/run/llm-proxy/rpc.sock"
```

Remote Elixir callers can execute `LLMProxy.chat` through SafeRPC. When Incant is installed, a separate Incant host can also discover and render LLMProxy's admin resources over this socket.

The public gateway does not mount an admin UI or Incant API. This keeps model traffic and operator access on separate interfaces. See [Admin Integration](../features/admin-integration.md).

## Observability

Set an OTLP endpoint to export traces:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4318"
```

Without that variable, OpenTelemetry instrumentation remains active but export is disabled.

Every generation receives a trace ID. HTTP responses return it as `x-request-id` and `x-llm-proxy-trace-id`; in-process responses expose `response.trace_id`.

## Deploying the release

See [Standalone Deployment](../deployment/standalone-deployment.md) for build commands, migration order, health checks, draining, and artifact generation.
