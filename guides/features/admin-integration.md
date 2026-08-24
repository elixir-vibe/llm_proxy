# Admin Integration

LLMProxy can expose an optional Incant admin surface for operational work. Incant is not required for routing, HTTP serving, accounting, or storage.

The integration follows a service-owned model:

- LLMProxy owns resource definitions, queries, policies, and actions.
- [SafeRPC](https://hexdocs.pm/safe_rpc) transports portable admin contracts and operation requests.
- A local or separate Incant host renders the UI and dispatches operations.
- The public LLM gateway does not mount an admin UI or admin HTTP API.

This separation lets operators place model traffic and administrative access on different listeners, users, and network policies.

## Enable Incant

Add Incant alongside LLMProxy in the application that owns LLMProxy storage:

```elixir
def deps do
  [
    {:llm_proxy, "~> 0.1"},
    {:incant, "~> 0.1"}
  ]
end
```

LLMProxy compiles its admin modules only when Incant is available. Without Incant, the gateway starts and serves normally.

## Available surfaces

`LLMProxy.Admin` exposes:

- **API keys** — create, inspect, edit, reveal once, and revoke client credentials; configure model access, limits, tracing, and content capture.
- **Provider tokens** — manage upstream API keys and OAuth credentials by isolated pool.
- **Traces** — inspect recorded request/response traces and feedback.
- **Messages** — inspect redacted message records and linked usage. Raw captured text stays on an authorized storage path.
- **Operations dashboard** — review request volume, token usage, spend, latency, and recent failures.
- **Provider Usage dashboard** — review each configured Codex or GLM Coding Plan account, its live upstream windows, remaining capacity, reset time, availability, and refresh state.

Policies remain inside the LLMProxy service VM. A remote Incant host receives data and dispatches actions; it does not receive repos, schemas, callback functions, or provider secrets as executable terms.

Captured message text is marked as sensitive in the Incant resource contract. LLMProxy redacts it before local table/detail rendering and before remote SafeRPC transport. Treat direct database and storage-facade access as privileged content access.

## Local admin in a host application

A Phoenix application that embeds both packages can mount `LLMProxy.Admin` with its router helper:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  use LLMProxy.Admin.Router

  scope "/" do
    pipe_through [:browser, :require_operator]
    llm_proxy_incant "/admin/llm", LLMProxy.Admin
  end
end
```

This helper adds a LiveView hook that reloads the Provider Usage dashboard once
each minute. It does not reload other admin pages. To use a different interval,
set `config :llm_proxy, admin_provider_usage_poll_interval_ms: 60_000`. The
supported page-poll interval is 15 seconds through one hour. Incant 0.1 does
not provide a dashboard-level auto-refresh switch. Change the Elixir setting
when the host needs a different interval.

Use the host application's authentication and authorization pipeline around the mount. `LLMProxy.Admin.Policy` governs service-level resource and action access, but it does not replace operator authentication at the web boundary.

## Remote admin over SafeRPC

Configure a Unix socket in the LLMProxy service:

```elixir
config :llm_proxy,
  rpc_socket: "/run/llm-proxy/rpc.sock"
```

Or in standalone TOML:

```toml
[server]
rpc_socket = "/run/llm-proxy/rpc.sock"
```

When a socket is configured, `LLMProxy.RPC.AdminServer` serves two operation namespaces:

- `LLMProxy.Admin` when Incant is installed;
- `LLMProxy.Ops` for drain and lifecycle operations.

A central Incant application loads a service registry, discovers `LLMProxy.Admin`, and mounts the registry:

```elixir
children = [
  {Incant.Service.RegistryServer, name: MyApp.IncantRegistry}
]
```

```elixir
incant "/admin", registry: MyApp.IncantRegistry
```

The registry binding maps the LLMProxy service to its SafeRPC socket. See Incant's service-interface guide for the registry file format and standalone Incant host configuration.

## Socket security

The SafeRPC server creates the socket with mode `0660`. Security still depends on deployment ownership and directory permissions.

- Put the socket in a root-owned runtime directory.
- Grant access only to the LLMProxy and Incant service groups.
- Do not expose the Unix socket through an untrusted filesystem mount.
- Keep the Incant HTTP listener behind operator authentication and network policy.
- Treat API-key reveal results and OAuth verifiers as secrets.

SafeRPC is a local service boundary, not an internet-facing transport.

## Codex OAuth

The provider-token resource includes actions to start and complete OpenAI Codex OAuth.

The start action returns an authorization URL plus state and verifier values. Open the URL, complete authorization, then submit the callback URL or code to the completion action. The verifier is temporary operator-only secret material.

On completion, LLMProxy stores refreshable credentials in `provider_tokens`. Later refreshes update the access token, refresh token, expiry, and account ID in the active service storage.

Prefer this live admin flow for standalone services because it uses the running storage owner. `bin/codex_login` remains available for local recovery, but starts a separate VM and may require the service to be stopped when storage ownership is exclusive.

Before any Codex token exists, Codex requests fail with `No available OpenAI Codex OAuth tokens: no_tokens` rather than falling through to an unrelated credential pool.

## Live provider usage

The provider-usage tracker starts with LLMProxy and keeps one in-memory snapshot per supported provider-token record. It runs one sequential refresh task. A second automatic or manual refresh cannot overlap it. Snapshots do not contain access tokens, refresh tokens, cookies, or provider account IDs. SafeRPC receives only the redacted account label, percentages, timestamps, availability, freshness, and safe error text.

OpenAI Codex usage comes from the same account-rate-limit source used by the [first-party Codex backend client](https://github.com/openai/codex/blob/main/codex-rs/backend-client/src/client/rate_limit_resets.rs). With the default `https://chatgpt.com/backend-api` base, LLMProxy uses `GET /backend-api/wham/usage`. A custom base without `/backend-api` uses its `/api/codex/usage` path. The request requires a valid Codex OAuth access token. `ChatGPT-Account-Id` is sent when the stored token or access-token claim provides it, but the ID is never returned to Incant.

For Codex accounts, the dashboard also shows the available rate-limit reset
credit count. When at least one credit is available on the first-party backend,
LLMProxy reads `GET /backend-api/wham/rate-limit-reset-credits` and shows the
earliest available credit expiry. This integration is read-only. LLMProxy does
not expose or call the credit-consumption endpoint. If the optional detail
request fails, the normal quota windows and credit count remain available.

GLM Coding Plan usage comes from the Z.AI monitor API on the configured provider origin. Providers using the `zai`, `zai_coder`, or `zai_coding_plan` ReqLLM adapter qualify automatically. A custom provider can set `usage_adapter: "glm"`. The default source order is:

1. `/api/monitor/usage/quota/limit`, used by [Z.AI's first-party GLM usage plugin](https://github.com/zai-org/zai-coding-plugins/blob/main/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs).
2. `/api/monitor/usage`, used only as a bounded fallback after an authentication or not-found reply because current Coding Plan responses have also been observed there.

The GLM monitor surface is not in the general public Z.AI API reference. Response forms differ by plan and rollout. LLMProxy accepts `TOKENS_LIMIT` and current `CREDIT_LIMIT` windows. It also accepts the monthly `TIME_LIMIT` tool window. If a reply does not contain `nextResetTime`, the dashboard shows no reset value. It does not calculate one.

Configure a GLM Coding Plan provider and an isolated token pool:

```toml
[providers.glm-coding]
adapter = "zai_coding_plan"
base_url = "https://api.z.ai/api/coding/paas/v4"
token_pool = "glm-production"
```

Add each account API key as a separate `provider_tokens` row in `glm-production`, or seed the pool through `LLM_PROXY_PROVIDER_KEYS`. Use a short operational label such as `prod-east`. Usage output always masks a valid label, for example `p***t`, and adds the local token ID. Labels with unsafe characters, including email addresses, become `Account #<local token id>`.

The first-party GLM usage plugin sends the API key as the raw `Authorization` value, which is the default. If the account endpoint requires a bearer scheme, set `usage_auth_scheme = "bearer"`. To select one qualified endpoint explicitly, set `usage_paths = ["/api/monitor/usage"]`. Usage URLs must use HTTPS, endpoint lists are limited to three paths, redirects are disabled, and responses are capped at 256,000 bytes before JSON decoding. Tokens with per-token endpoint overrides are reported as unsupported without sending their credentials; configure a provider-level usage origin instead.

Automatic refresh defaults to five minutes. The supported interval is one minute through one hour. The request deadline is one through 30 seconds. Standalone settings belong in TOML:

```toml
[provider_usage]
auto_refresh = true
refresh_interval_ms = 300000
request_timeout_ms = 10000
stale_after_ms = 600000
```

Library applications can set the same values in application configuration:

```elixir
config :llm_proxy,
  provider_usage_auto_refresh: true,
  provider_usage_refresh_interval_ms: 300_000,
  provider_usage_request_timeout_ms: 10_000,
  provider_usage_stale_after_ms: 600_000,
  admin_provider_usage_poll_interval_ms: 60_000
```

The local Incant hook reloads the dashboard once each minute. This page poll
does not make an upstream request or change the provider refresh interval. Set
`provider_usage.refresh_interval_ms = 60000` in standalone TOML, or
`provider_usage_refresh_interval_ms: 60_000` in library configuration, when the
dashboard must receive new upstream values each minute.

Set `provider_usage.auto_refresh = false` in standalone TOML to use only the Provider Tokens resource actions. Library applications set `provider_usage_auto_refresh: false` in Elixir configuration. `Refresh provider usage` starts a bounded refresh of all supported accounts. The row action refreshes one supported account. Both actions return before upstream I/O completes, so they stay inside the SafeRPC request deadline.

Disabled tokens appear as unavailable and are not decoded or sent. Authentication failures, unsupported or absent quota APIs, timeouts, rate limits, malformed responses, and stale retained data have separate states. A failed refresh keeps the last successful windows and marks them stale.

Token selection consumes this state. It skips an exhausted fresh account until the reported reset.
It also skips stale or failed account state until a successful refresh proves capacity again.

## Backups

Admin state is operational state. Back up the configured LLMProxy database, including:

- API-key hashes and policy fields;
- provider tokens and OAuth refresh material;
- provider-token and model cooldown reset times;
- usage, messages, traces, and feedback required by retention policy.

Do not back up transient SafeRPC socket files. Restore the database, recreate runtime directories and permissions, run migrations, then let services recreate sockets.

Content capture has no automatic expiry. Set a retention period for captured messages and trace bodies, and apply it in the application that owns the database. `LLMProxy.Storage.delete_key/1` removes all content and accounting rows owned by that key. Disabling capture stops new content writes but does not delete old rows.
