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

Policies remain inside the LLMProxy service VM. A remote Incant host receives data and dispatches actions; it does not receive repos, schemas, callback functions, or provider secrets as executable terms.

Captured message text is marked as sensitive in the Incant resource contract. LLMProxy redacts it before local table/detail rendering and before remote SafeRPC transport. Treat direct database and storage-facade access as privileged content access.

## Local admin in a host application

A Phoenix application that embeds both packages can mount `LLMProxy.Admin` directly through Incant's router:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  use Incant.Router

  scope "/" do
    pipe_through [:browser, :require_operator]
    incant "/admin/llm", LLMProxy.Admin
  end
end
```

Use the host application's authentication and authorization pipeline around the mount. `LLMProxy.Admin.Policy` governs service-level resource and action access, but it does not replace operator authentication at the web boundary.

## Remote admin over SafeRPC

Configure a Unix socket in the LLMProxy service:

```elixir
config :llm_proxy,
  rpc_socket: "/run/llm-proxy/rpc.sock"
```

Or in the standalone release:

```bash
LLM_PROXY_RPC_SOCKET="/run/llm-proxy/rpc.sock"
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

## Backups

Admin state is operational state. Back up the configured LLMProxy database, including:

- API-key hashes and policy fields;
- provider tokens and OAuth refresh material;
- usage, messages, traces, and feedback required by retention policy.

Do not back up transient SafeRPC socket files. Restore the database, recreate runtime directories and permissions, run migrations, then let services recreate sockets.

Content capture has no automatic expiry. Set a retention period for captured messages and trace bodies, and apply it in the application that owns the database. `LLMProxy.Storage.delete_key/1` removes all content and accounting rows owned by that key. Disabling capture stops new content writes but does not delete old rows.
