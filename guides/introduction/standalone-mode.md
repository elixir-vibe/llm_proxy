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

Set only secrets and the optional config-file location in the service
environment:

```bash
MASTER_KEY="replace-with-a-long-random-key"
LLM_PROXY_PROVIDER_KEYS='{"openai":["sk-primary"],"anthropic":["sk-ant-..."]}'
LLM_PROXY_PROVIDER_TOKEN_KEYRING='{"active_key_id":"2026-08","keys":{"2026-08":"base64-encoded-32-byte-key"}}'
LLM_PROXY_CONFIG_TOML="/etc/llm-proxy/config.toml"
```

`MASTER_KEY` is the bootstrap and operator credential. `LLM_PROXY_PROVIDER_KEYS`
seeds API-key pools by pool name. Existing records remain the runtime source
after seeding. Provision Codex OAuth through the admin login flow rather than an
environment variable.

The provider-token keyring is separate from `MASTER_KEY`. Store it in the
service secret manager and back it up separately from the database. Loss of all
keyring copies makes encrypted provider tokens unrecoverable. Keep prior key IDs
in the JSON map until all rows are rotated and verified.

The same JSON object can seed isolated pools for configuration-driven providers:

```bash
LLM_PROXY_PROVIDER_KEYS='{"example-production":["secret-key"]}'
```

Never put API keys, OAuth tokens, encryption keys, or proxy credentials in TOML.
The strict TOML loader rejects provider credential fields.

## Data configuration

The release optionally reads `/etc/llm-proxy/config.toml`. Override that path with `LLM_PROXY_CONFIG_TOML`.

```toml
[server]
port = 4000
public_url = "https://llm.example.com"
body_limit_bytes = 32000000
rpc_socket = "/run/llm-proxy/rpc.sock"

[storage]
database = "/var/lib/llm-proxy/llm_proxy.duckdb"
quackdb_uri = "http://127.0.0.1:9494"
quackdb_endpoint = "quack:localhost:9494"

[routing]
max_retries = 1
replay_policy = "safe_only"
provider_connect_timeout_ms = 10000

[telemetry]
otlp_endpoint = "http://127.0.0.1:4318"

[provider_tokens]
allow_plaintext = true
selection_strategy = "affinity"

[catalog]
public_models = ["coding"]

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

The TOML loader accepts server, storage, routing, telemetry,
provider-token rollout, catalog, provider, and model data. The optional
`catalog.public_models` list exposes only named visible catalog aliases for
model discovery and request admission; an empty list exposes none. It rejects
unknown keys rather than silently ignoring misspelled settings. Secrets remain
in environment variables or persisted provider-token storage. If the file is absent, startup
continues with compiled defaults and secret environment configuration. Set
`provider_tokens.allow_plaintext = false` only after encrypting and verifying all
stored credentials; with that policy, a missing keyring fails startup.
`provider_tokens.selection_strategy` accepts `affinity` or `fill_first` and is
not read from the environment.

See [Providers and Routing](../features/providers-and-routing.md) for the complete model shape.

## Storage

Production uses `LLMProxy.Storage.Repo.QuackDB` and a managed QuackDB process.
Configure its database path, Ecto URI, and listener endpoint under `[storage]` in
TOML. Defaults are `./llm_proxy.duckdb`, `http://127.0.0.1:9494`, and
`quack:localhost:9494` respectively.

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

The default authenticated JSON body limit is 32 MB. Set
`server.body_limit_bytes` to a positive integer to change it. Authentication and
quota checks run before the body is read and decoded.

Streaming endpoints emit SSE comment heartbeats while an upstream stream is silent. Heartbeats keep connections alive without changing OpenAI or Anthropic event payloads.

## SafeRPC and admin

Set `server.rpc_socket` in TOML to start the SafeRPC server:

```toml
[server]
rpc_socket = "/run/llm-proxy/rpc.sock"
```

Remote Elixir callers can execute `LLMProxy.chat` through SafeRPC. When Incant is installed, a separate Incant host can also discover and render LLMProxy's admin resources over this socket.

The public gateway does not mount an admin UI or Incant API. This keeps model traffic and operator access on separate interfaces. See [Admin Integration](../features/admin-integration.md).

## Observability

Set `telemetry.otlp_endpoint` in TOML to export traces:

```toml
[telemetry]
otlp_endpoint = "http://127.0.0.1:4318"
```

Without that setting, OpenTelemetry instrumentation remains active but export is
disabled.

Every generation receives a trace ID. HTTP responses return it as `x-request-id` and `x-llm-proxy-trace-id`; in-process responses expose `response.trace_id`.

## Deploying the release

See [Standalone Deployment](../deployment/standalone-deployment.md) for build commands, migration order, health checks, draining, and artifact generation.
