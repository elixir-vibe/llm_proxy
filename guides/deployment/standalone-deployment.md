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
/etc/llm-proxy/config.toml            non-secret runtime, provider, and model data
/var/lib/llm-proxy/llm_proxy.duckdb   persistent database
/run/llm-proxy/rpc.sock               optional SafeRPC socket
```

Keep the database and runtime directory outside immutable release paths. Do not store provider secrets in the TOML file or release archive.

## Runtime environment

The standalone environment contains only secrets and the optional TOML locator:

```bash
MASTER_KEY="replace-with-a-long-random-key"
LLM_PROXY_PROVIDER_KEYS='{"openai":["sk-..."],"custom-production":["secret"]}'
LLM_PROXY_CONFIG_TOML="/etc/llm-proxy/config.toml"
```

Add `LLM_PROXY_PROVIDER_TOKEN_KEYRING` when using encrypted provider-token
storage. Configure the HTTP listener, public URL, database, RPC socket, routing,
and OTLP endpoint in TOML. Provider-specific API-key and Codex-token environment
variables are not supported; use named API-key pools and persisted Codex OAuth
credentials.

See the [Configuration Cheatsheet](../reference/configuration.cheatmd) for the
complete environment and TOML schema.

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

When `server.rpc_socket` is configured in TOML, release tasks can coordinate drain state through the running service:

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

## Provider-token encryption

Use a provider-token keyring that is separate from `MASTER_KEY`. Before the first
encryption, back up the database and all keyring values. Start with plaintext
compatibility enabled, then run:

```bash
bin/llm_proxy eval 'LLMProxy.ReleaseTasks.provider_tokens_status()'
bin/llm_proxy eval 'LLMProxy.ReleaseTasks.provider_tokens_encrypt()'
bin/llm_proxy eval 'LLMProxy.ReleaseTasks.provider_tokens_verify()'
```

Run these tasks only with a backup and a storage-concurrency plan appropriate
for the deployment. For bundled QuackDB, drain and stop the long-lived service
before an offline release task opens the same database. The tasks print counts
only; they do not print credentials.

Test provider calls before you set `provider_tokens.allow_plaintext = false` in
standalone TOML. Before that verification point, you can restore plaintext and
use the prior release:

```bash
bin/llm_proxy eval 'LLMProxy.ReleaseTasks.provider_tokens_decrypt()'
```

For key rotation, add the new and prior keys, set the new active key ID, and run:

```bash
bin/llm_proxy eval 'LLMProxy.ReleaseTasks.provider_tokens_rotate()'
bin/llm_proxy eval 'LLMProxy.ReleaseTasks.provider_tokens_verify()'
```

Remove a prior key only after rotation, verification, provider checks, and a new
database backup. Keep an offline recovery copy of every key needed by retained
backups.

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
