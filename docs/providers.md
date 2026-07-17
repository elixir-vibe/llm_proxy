# Providers

`LLMProxy.Provider` is the execution boundary. Provider modules only implement upstream-specific request execution and response conversion.

## Configuration-driven providers

Use configuration, not a new LLMProxy module, when ReqLLM already supports the upstream protocol. A named provider declares a ReqLLM `adapter`, endpoint, and default token pool; public model aliases route to that provider and upstream model ID.

Embedded Elixir configuration:

```elixir
config :llm_proxy,
  providers: %{
    "my-service" => %{
      adapter: "openai",
      base_url: "https://api.example.com/v1",
      token_pool: "my-service-production"
    }
  },
  models: [
    [
      name: "my-service/model",
      routes: [[to: "my-service", model: "upstream-model-id"]]
    ]
  ]
```

Standalone TOML configuration:

```toml
[providers.my-service]
adapter = "openai"
base_url = "https://api.example.com/v1"
token_pool = "my-service-production"

[[models]]
name = "my-service/model"

[[models.routes]]
to = "my-service"
model = "upstream-model-id"
```

The adapter name must match a registered ReqLLM provider ID, such as `openai`, `anthropic`, or another provider returned by `ReqLLM.Providers.list/0`. LLMProxy resolves this finite registry without creating atoms from configuration.

`token_pool` defaults at provider level and may be overridden on an individual route. Provider-token rows select a pool through their `provider` field. This isolates credentials even when several services use the same ReqLLM adapter.

Standalone releases can bootstrap arbitrary API-key pools with one secret environment variable:

```text
LLM_PROXY_PROVIDER_KEYS={"my-service-production":["secret-key"]}
```

Persisted provider tokens remain the runtime source after seeding. Never put credentials in TOML, Elixir config committed to source control, model metadata, or route metadata.

A provider-token `proxy` value overrides the configured base URL for that token. Use it only for an intentional per-token gateway; prefer the named provider's `base_url` for normal service endpoints.

Configuration-driven ReqLLM providers currently serve the normalized chat execution path, including `/v1/chat/completions`, local `LLMProxy.chat/2`, streaming, reasoning deltas, tools, and usage. Native wire passthrough endpoints require a provider that explicitly supports that native API.

## When provider code is justified

Do not create an LLMProxy provider module merely for a different base URL, credential pool, or model ID. Implement `LLMProxy.Providers.Behaviour` only when ReqLLM does not support the authentication or wire protocol. Prefer adding generally useful protocol support upstream to ReqLLM.

The built-in `LLMProxy.Providers.OpenAICompatible` transport remains for bundled compatibility providers, but it is not the extension mechanism for end-user configuration.

## OpenAI Codex OAuth tokens

`openai-codex` uses OAuth provider tokens. Plain access-token entries are supported but cannot be refreshed. Refreshable entries use this seed format:

```text
access_token|refresh_token|expires_unix_ms|account_id
```

`account_id` is optional. Refreshed credentials are stored back into `provider_tokens` as `token`, `refresh_token`, `expires_at`, and `account_id`.

Preferred standalone releases manage Codex OAuth through the live Incant admin API. This keeps token persistence inside the running service and avoids starting a second storage owner.

Start the OAuth flow:

```bash
curl -sS -X POST \
  -H 'content-type: application/json' \
  -H 'accept: application/vnd.incant.admin+json' \
  --data '{"payload": {}}' \
  http://127.0.0.1:4000/incant/services/llm_proxy/surfaces/provider_token/actions/codex_oauth_start/runs
```

Open the returned `result.meta.oauth.authorization_url`. Keep the returned `state` and `verifier`; the verifier is sensitive and should be treated like an operator-only secret for the duration of the login.

Complete the flow with the pasted callback URL or authorization code:

```bash
curl -sS -X POST \
  -H 'content-type: application/json' \
  -H 'accept: application/vnd.incant.admin+json' \
  --data '{
    "payload": {
      "input": {
        "authorization_input": "PASTED_CALLBACK_URL_OR_CODE",
        "state": "STATE_FROM_START",
        "verifier": "VERIFIER_FROM_START"
      }
    }
  }' \
  http://127.0.0.1:4000/incant/services/llm_proxy/surfaces/provider_token/actions/codex_oauth_complete/runs
```

Verify the token through Incant rows or storage inspection:

```bash
curl -sS \
  -H 'accept: application/vnd.incant.admin+json' \
  http://127.0.0.1:4000/incant/services/llm_proxy/surfaces/provider_token/rows
```

Before a token is present, Codex requests fail with `No available OpenAI Codex OAuth tokens: no_tokens`. After login, refreshed credentials are persisted automatically.

`bin/codex_login` remains available for local/manual recovery use, but it runs in a separate VM. If a release uses exclusive local storage such as a managed DuckDB/QuackDB process, prefer the live Incant flow above instead of stopping the service to run the helper.

## Custom providers

Implement `LLMProxy.Providers.Behaviour` when the upstream is not OpenAI-compatible:

```elixir
defmodule MyApp.LLM.CustomProvider do
  @behaviour LLMProxy.Providers.Behaviour

  alias LLMProxy.Providers.Result
  alias LLMProxy.TokenPool.Server, as: TokenPool

  def name, do: "custom"
  def native_protocol, do: :openai
  def models, do: ["custom-model"]

  def call(body, user_id) do
    with {:ok, token} <- TokenPool.pick_token(name(), user_id) do
      # perform upstream request
      {:ok, Result.response(%{}, token)}
    end
  end

  def stream(body, user_id) do
    with {:ok, token} <- TokenPool.pick_token(name(), user_id) do
      {:ok, Result.stream([], token)}
    end
  end

  def extract_usage(response), do: LLMProxy.Usage.zero()
  def to_openai_response(response, model), do: Map.put(response, "model", model)
end
```

Useful provider modules:

- `LLMProxy.Providers.Execution` — attempt execution, fallback, timeout, telemetry, and circuit-breaker handling.
- `LLMProxy.Providers.HTTPResult` — common HTTP response-to-result conversion and retry-after parsing.
- `LLMProxy.Providers.Result` — explicit response, stream, and error result variants.
- `LLMProxy.Providers.OpenAICompatible` — shared OpenAI-compatible `/chat/completions` client.

## Native passthrough

Providers may optionally implement native passthrough callbacks:

```elixir
def call_native(body, user_id), do: call(body, user_id)
def stream_native(body, user_id), do: stream(body, user_id)
```

`/v1/messages` and `/v1/responses` route through `LLMProxy.Provider.call_native/3` and `stream_native/3`, so native calls still receive catalog routing, fallback, timeout, circuit-breaker, and retry-after behavior.

## Catalog deployments

Use catalog deployments when a public model should route to one or more upstream deployments:

```elixir
LLMProxy.Catalog.put_model(%{
  id: "fast",
  deployments: [
    %{provider: MyApp.LLM.MyProvider, upstream_model: "my-model", weight: 2}
  ],
  routing: :weighted_shuffle
})
```
