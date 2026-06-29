# Providers

`LLMProxy.Provider` is the execution boundary. Provider modules only implement upstream-specific request execution and response conversion.

## OpenAI-compatible providers

For providers that expose `/chat/completions`, use `LLMProxy.Providers.OpenAICompatible.Definition`:

```elixir
defmodule MyApp.LLM.MyProvider do
  use LLMProxy.Providers.OpenAICompatible.Definition,
    name: "my-provider",
    models: ["my-model"],
    config_key: "my-provider"
end
```

Configure provider defaults and seed tokens:

```elixir
config :llm_proxy,
  providers: %{
    "my-provider" => %{
      api_keys: System.get_env("MY_PROVIDER_API_KEYS", ""),
      base_url: "https://api.example.com/v1"
    }
  }
```

Register the provider at application startup:

```elixir
LLMProxy.Providers.Registry.register(MyApp.LLM.MyProvider)
```

Optional headers can be set through config or macro defaults:

```elixir
defmodule MyApp.LLM.OpenRouterLike do
  use LLMProxy.Providers.OpenAICompatible.Definition,
    name: "openrouter-like",
    http_referer: "https://my-app.example",
    title: "My App"
end
```

Token-level `proxy` values override the configured base URL, so deployments can route through provider-specific gateways.

## OpenAI Codex OAuth tokens

`openai-codex` uses OAuth provider tokens. Plain access-token entries are supported but cannot be refreshed. Refreshable entries use this seed format:

```text
access_token|refresh_token|expires_unix_ms|account_id
```

`account_id` is optional. Refreshed credentials are stored back into `provider_tokens` as `token`, `refresh_token`, `expires_at`, and `account_id`.

Standalone releases can run `bin/codex_login` for an interactive OAuth flow:

```bash
bin/codex_login
```

The command prints the ChatGPT/Codex authorization URL, accepts a pasted redirect URL or authorization code, exchanges it server-side, and stores the resulting OAuth token in `provider_tokens`. Before a token is present, Codex requests fail with `No available OpenAI Codex OAuth tokens: no_tokens`. After login, refreshed credentials are persisted automatically.

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
