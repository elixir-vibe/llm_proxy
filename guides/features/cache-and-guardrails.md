# Cache and Guardrails

LLMProxy exposes small behaviours for deterministic response caching and request/response policy. The gateway owns when hooks run; the host application owns storage and policy decisions.

Neither feature requires a hosted control plane or bundled policy engine.

## Deterministic cache

Configure one cache adapter:

```elixir
config :llm_proxy,
  cache: MyApp.LLMCache,
  cache_policy: [
    ttl_ms: 60_000,
    models: %{
      "no-cache-model" => [enabled: false],
      "slow-model" => [ttl_ms: 300_000]
    }
  ]
```

Implement `LLMProxy.Cache`:

```elixir
defmodule MyApp.LLMCache do
  @behaviour LLMProxy.Cache

  @impl true
  def get(key, context) do
    case MyCache.get(key) do
      nil -> :miss
      response -> {:hit, response}
    end
  end

  @impl true
  def put(key, response, context) do
    MyCache.put(key, response, ttl: context[:cache_ttl_ms])
    :ok
  end
end
```

Adapters receive and return `%LLMProxy.Response{}`. External caches can serialize that struct, but must restore it before returning a hit.

`put/3` is optional. Adapter errors and unexpected values degrade to cache misses or ignored writes rather than breaking provider execution.

## Cache keys

Keys are SHA-256 hashes derived from:

- request protocol and public model;
- normalized conversation messages;
- tools and tool choice;
- generation parameters such as token limit, temperature, top-p, and stop sequences;
- resolved provider and upstream-model attempts.

The attempt list is part of the key so catalog changes do not silently reuse a response produced by a different deployment plan.

Streaming requests are never cached.

## Cache policy

Global and per-model settings support:

```elixir
config :llm_proxy,
  cache_policy: [
    enabled: true,
    ttl_ms: 60_000,
    models: %{
      "fast" => [ttl_ms: 30_000],
      "fresh" => [enabled: false]
    }
  ]
```

Request metadata can bypass or narrow policy:

```elixir
metadata: %{"no_cache" => true}
metadata: %{"cache" => false}
metadata: %{"cache_ttl_ms" => 15_000}
```

Only positive integer TTLs are accepted. A response is written only when `response.cacheable` is true. Cache hits set `response.cache_hit` and receive the current request and trace ID.

## Guardrails

Configure guardrails in execution order:

```elixir
config :llm_proxy,
  guardrails: [
    MyApp.BlockSecrets,
    MyApp.RedactOutput
  ]
```

Implement any callbacks needed by the module:

```elixir
defmodule MyApp.BlockSecrets do
  @behaviour LLMProxy.Guardrail

  alias LLMProxy.Protocol.Request
  alias LLMProxy.Response
  alias LLMProxy.Stream.Event

  @impl true
  def before_request(%Request{} = request, context) do
    if allowed?(request, context), do: {:ok, request}, else: {:error, :blocked}
  end

  @impl true
  def after_response(%Response{} = response, _context) do
    {:ok, response}
  end

  @impl true
  def on_stream_event(%Event{} = event, _context) do
    {:ok, event}
  end
end
```

Callbacks are optional and run in configured order.

### `before_request/2`

Runs after actor, key, quota, and model-access checks but before provider resolution and cache lookup. Return:

- `{:ok, request}` to continue with the original or transformed request;
- `{:error, reason}` to reject it.

A rejection becomes a permission-style error for callers.

### `after_response/2`

Runs after a non-stream provider response is normalized and before cache write and usage tracking. Return a response to continue or an error to reject it.

### `on_stream_event/2`

Runs for each normalized stream event. Return:

- `{:ok, event}` to emit it;
- `{:ok, nil}` to filter it;
- `{:error, reason}` to halt the stream.

Keep stream hooks fast and side-effect-light because they execute in the consumer's enumeration path.

## Hook context

Cache and guardrail callbacks receive context that may include:

```elixir
%{
  actor: %LLMProxy.Actor{},
  api_key: api_key,
  route: :chat,
  model: "upstream-model",
  provider: ProviderModule,
  provider_name: "openai-primary",
  trace_id: "...",
  cache_key: "...",
  metadata: %{}
}
```

Not every field exists at every stage. Request guardrails run before provider selection, while response and stream hooks receive the selected provider and upstream model.

## Design guidance

Use guardrails for deterministic application policy such as allow, deny, validation, and masking. Keep external network calls, long-running classifiers, and stateful orchestration outside synchronous hooks unless their latency and failure semantics are deliberate.

Use the cache for exact normalized-request reuse. Semantic similarity search is intentionally not part of the core cache contract.
