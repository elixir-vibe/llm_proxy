# Standalone Deployment

The standalone OTP release owns its HTTP listener, DuckDB-backed storage, provider token pools, model catalog, and optional [SafeRPC](https://hexdocs.pm/safe_rpc) socket.

This guide covers the release itself. Package deployment systems should wrap these steps with immutable artifacts, secret injection, service supervision, backups, and rollback appropriate to the host.

## Build a Mix release

From the LLMProxy source checkout:

```bash
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix release llm_proxy
```

The release is written to:

```text
_build/prod/rel/llm_proxy
```

Its runtime configuration:

- uses DuckDB through the bundled QuackDB adapter;
- starts a managed local QuackDB process;
- binds the HTTP listener to `127.0.0.1`;
- optionally loads `/etc/llm-proxy/config.toml`;
- reads secrets and operational values from the environment.

## Build a ReleaseKit artifact

ReleaseKit can package the Mix release as an immutable tarball with a machine-readable manifest:

```bash
MIX_ENV=prod mix release_kit.artifact --out-dir _build/prod/artifacts
```

Output:

```text
_build/prod/artifacts/llm_proxy-<version>.tar.gz
_build/prod/artifacts/llm_proxy.etf
```

Use the standard Mix release directly when your deployment system does not consume ReleaseKit manifests.

## Filesystem layout

A typical host uses:

```text
/opt/llm-proxy/releases/<release>/    immutable unpacked release
/opt/llm-proxy/current/               symlink to active release
/etc/llm-proxy/config.toml            non-secret provider and model data
/var/lib/llm-proxy/llm_proxy.duckdb   persistent database
/run/llm-proxy/rpc.sock               optional SafeRPC socket
```

Keep the database and runtime directory outside immutable release paths. Do not store provider secrets in the TOML file or release archive.

## Runtime environment

Minimal production variables:

```bash
MASTER_KEY="replace-with-a-long-random-key"
DATABASE_PATH="/var/lib/llm-proxy/llm_proxy.duckdb"
PORT="4000"
PUBLIC_URL="https://llm.example.com"
```

At least one provider pool also needs credentials:

```bash
OPENAI_API_KEYS="sk-..."
ANTHROPIC_API_KEYS="sk-ant-..."
OPENROUTER_API_KEYS="sk-or-..."
LLM_PROXY_PROVIDER_KEYS='{"custom-production":["secret"]}'
```

Optional service integration:

```bash
LLM_PROXY_CONFIG_TOML="/etc/llm-proxy/config.toml"
LLM_PROXY_RPC_SOCKET="/run/llm-proxy/rpc.sock"
OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4318"
```

See the [Configuration Cheatsheet](../reference/configuration.cheatmd) for all supported variables.

## Migrate before startup

Run migrations from the new release with the same storage environment the service will use:

```bash
/opt/llm-proxy/current/bin/llm_proxy eval 'LLMProxy.ReleaseTasks.migrate()'
```

The migration task starts its own temporary QuackDB dependency, applies all pending migrations, checkpoints the database, and stops.

Do not run migration and the long-lived service against the same exclusive local database concurrently unless the storage deployment explicitly supports it.

## Start and verify

Start under your service supervisor, or manually for a smoke test:

```bash
/opt/llm-proxy/current/bin/llm_proxy start
```

Verify health:

```bash
curl --fail --silent http://127.0.0.1:4000/health
```

A healthy response reports readiness, drain state, and active work counts. Then verify:

1. `/v1/models` contains intended public aliases.
2. An authenticated non-streaming completion succeeds.
3. A streaming completion emits text and terminates normally.
4. Usage, provider identity, and trace ID are recorded.
5. The reverse proxy preserves streaming and request IDs.
6. OTLP export works when configured.
7. The SafeRPC socket has expected ownership and mode when enabled.

## Reverse proxy

LLMProxy binds loopback only. Terminate public TLS and enforce network policy in a reverse proxy or ingress.

The proxy must:

- support long-lived streaming responses;
- avoid buffering SSE bodies;
- allow the configured request body limit;
- preserve `Authorization`, `x-api-key`, and request-ID headers;
- use an idle timeout longer than the expected stream silence window.

LLMProxy sends SSE comment heartbeats during upstream silence, but every intermediary must still permit streaming flushes.

## Graceful replacement

When `LLM_PROXY_RPC_SOCKET` is configured, release tasks can coordinate drain state through the running service:

```bash
bin/llm_proxy eval 'LLMProxy.ReleaseTasks.drain_start()'
bin/llm_proxy eval 'LLMProxy.ReleaseTasks.drain_await(1_800_000)'
```

Drain mode stops accepting new tracked work while existing requests, streams, and agents finish. Check status with:

```bash
bin/llm_proxy eval 'LLMProxy.ReleaseTasks.drain_status()'
```

Cancel a drain if replacement is aborted:

```bash
bin/llm_proxy eval 'LLMProxy.ReleaseTasks.drain_cancel()'
```

After active work reaches zero, stop the old release and start the new one. Your service supervisor should enforce a bounded shutdown timeout longer than the application's drain window.

## Rollback

Application rollback and schema rollback are different decisions.

1. Stop or drain the current release.
2. Point the active symlink at the previous immutable release.
3. Start it with the same persistent database and secret environment.
4. Verify health, catalog, completion, and storage access.

Bundled migrations are forward migrations. Do not reverse database changes automatically unless the release documents and tests a safe down migration. Take a database backup before any migration that could make rollback incompatible.

## Backups

Back up the DuckDB file while storage is in a consistent state. Include:

- API-key hashes and policies;
- provider API keys and OAuth refresh material;
- catalog-independent operational state;
- usage, traces, messages, and feedback required by retention policy.

Exclude:

- release archives already stored elsewhere;
- SafeRPC socket files;
- logs, caches, and temporary QuackDB runtime files.

Document restore order: restore data, install release, recreate runtime directories and permissions, migrate, start, and verify.
