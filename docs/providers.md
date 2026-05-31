# Providers

`LLMProxy.Provider` is the execution boundary. Provider modules only implement upstream-specific request execution and response conversion.

## OpenAI-compatible providers

For providers that expose `/chat/completions`, use `LLMProxy.Providers.OpenAICompatibleProvider`:

```elixir
defmodule MyApp.LLM.MyProvider do
  use LLMProxy.Providers.OpenAICompatibleProvider,
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
  use LLMProxy.Providers.OpenAICompatibleProvider,
    name: "openrouter-like",
    http_referer: "https://my-app.example",
    title: "My App"
end
```

Token-level `proxy` values override the configured base URL, so deployments can route through provider-specific gateways.

## Custom providers

Implement `LLMProxy.Providers.Behaviour` when the upstream is not OpenAI-compatible:

```elixir
defmodule MyApp.LLM.CustomProvider do
  @behaviour LLMProxy.Providers.Behaviour

  alias LLMProxy.Providers.{Result, TokenAccess}

  def name, do: "custom"
  def native_protocol, do: :openai
  def models, do: ["custom-model"]

  def call(body, user_id) do
    with {:ok, token} <- TokenAccess.pick_token(name(), user_id) do
      # perform upstream request
      {:ok, Result.response(%{}, token)}
    end
  end

  def stream(body, user_id) do
    with {:ok, token} <- TokenAccess.pick_token(name(), user_id) do
      {:ok, Result.stream([], token)}
    end
  end

  def extract_usage(response), do: LLMProxy.Usage.zero()
  def to_openai_response(response, model), do: Map.put(response, "model", model)
end
```

Useful provider helpers:

- `LLMProxy.Providers.TokenAccess` — token selection with structured errors.
- `LLMProxy.Providers.Errors` — provider error extraction, retry-after parsing, rate-limit marking.
- `LLMProxy.Providers.ResponseHandler` — common JSON POST response handling.
- `LLMProxy.Providers.SSE` — SSE parsing.
- `LLMProxy.Providers.OpenAIStream` — OpenAI-compatible stream event conversion.

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
