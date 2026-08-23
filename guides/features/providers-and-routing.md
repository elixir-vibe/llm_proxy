# Providers and Routing

LLMProxy separates the model name a client requests from the upstream deployment that handles it.

A **provider** describes protocol, endpoint, and credential pool. A **model** gives clients a stable public name. A model has one or more **routes**, each pointing at an upstream provider and model ID.

```text
client model "fast"
        │
        ▼
public catalog model
        │
        ├── openai-primary / gpt-4.1-mini
        └── anthropic-primary / claude-3-5-haiku-20241022
```

## Prefer configuration over provider modules

When ReqLLM already supports an upstream protocol, declare a named provider instead of adding Elixir code:

```elixir
config :llm_proxy,
  providers: %{
    "example-service" => %{
      adapter: "openai",
      base_url: "https://api.example.com/v1",
      token_pool: "example-production"
    }
  },
  models: [
    [
      name: "example/model",
      routes: [[to: "example-service", model: "upstream-model-id"]]
    ]
  ]
```

Standalone TOML expresses the same data:

```toml
[providers.example-service]
adapter = "openai"
base_url = "https://api.example.com/v1"
token_pool = "example-production"

[[models]]
name = "example/model"

[[models.routes]]
to = "example-service"
model = "upstream-model-id"
```

`adapter` must be a provider ID registered with ReqLLM. LLMProxy resolves that finite registry and never creates atoms from provider names in data configuration.

A different endpoint, credential pool, or model ID does not justify a new provider module. Add code only when the upstream requires an authentication or wire protocol that ReqLLM does not support; prefer contributing generally useful protocol support to ReqLLM first.

## Credential isolation

`token_pool` defaults at provider level and can be overridden on a route. Provider-token records join a pool through their `provider` field.

Keep pools separate even when two services use the same adapter:

```text
provider: openai-primary    adapter: openai    token_pool: openai-production
provider: internal-gateway adapter: openai    token_pool: internal-production
```

This prevents credentials from crossing endpoints during retries or fallback.

Standalone releases can bootstrap named pools from secret environment state:

```bash
LLM_PROXY_PROVIDER_KEYS='{"example-production":["secret-a","secret-b"]}'
```

Persisted provider tokens remain the runtime source after seeding. A token record can override the provider base URL through its `proxy` field, but that should be reserved for intentional per-token gateways; normal endpoints belong in provider configuration.

## Public model aliases

A readable library configuration uses model aliases and routes:

```elixir
config :llm_proxy,
  models: [
    fast: [
      routing: :ordered,
      routes: [
        [
          to: :openai,
          model: "gpt-4.1-mini",
          timeout: 15_000,
          failure_threshold: 3,
          cooldown_ms: 30_000
        ],
        [
          to: :anthropic,
          model: "claude-3-5-haiku-20241022",
          order: 2
        ]
      ]
    ]
  ]
```

Clients request `fast`; they do not need to know which deployment answered. The response and stored usage still record the actual provider and upstream model.

The lower-level `:catalog` configuration with explicit `LLMProxy.Catalog.Model` and deployment structs remains available for advanced and existing applications.

## Routing strategies

Routing happens within each `order` group. Lower order groups are attempted first.

- `:ordered` — stable route order.
- `:shuffle` — randomize routes in an order group.
- `:round_robin` — rotate the first route across requests.
- `:weighted_shuffle` — randomize by route `weight`.
- `:lowest_cost` — order routes by LLMDB input and output pricing.

A route can define:

| Option | Purpose |
|---|---|
| `to` | Named or built-in provider |
| `model` | Upstream model ID |
| `order` | Fallback group; lower values run first |
| `weight` | Relative weight for `:weighted_shuffle` |
| `token_pool` | Route-specific credential pool |
| `timeout` / `timeout_ms` | Provider attempt deadline |
| `failure_threshold` | Consecutive retryable failures before opening the circuit |
| `cooldown_ms` | Time before an open deployment becomes eligible again |
| `hidden` | Hide the public model from model listing when configured on the model |
| `metadata` | Operator-defined catalog metadata |

## Failure handling

LLMProxy resolves an ordered list of deployment attempts, then:

1. skips deployments with open circuit breakers;
2. picks an available credential from the route's token pool;
3. checks the finite provider-dispatch budget;
4. executes with the route timeout;
5. classifies failure replay as safe, uncertain, or forbidden;
6. applies `Retry-After` cooldowns to rate-limited credentials;
7. falls through only when the replay policy permits it;
8. records the provider and model that ultimately handled the request.

Authentication failures and other forbidden replays are returned directly. Unavailable credentials, circuit skips, clear connection failures, and 429 refusals can safely move to another route. A timeout or 5xx response is uncertain because the upstream can have accepted billable work. The default `:safe_only` policy does not replay uncertain failures. Set `replay_policy: :allow_uncertain` only when duplicate cost and side effects are acceptable. Once any stream is returned to the caller, a later stream failure never starts another provider.

`max_attempts` is the strict dispatch limit for every request. It defaults to `max_retries + 1` for compatibility. Open-circuit and unsupported-protocol skips do not consume a dispatch. Routing telemetry includes the attempt number, limit, replay safety, decision, and reason. It never includes request content.

Public HTTP and SSE failures use the endpoint's native protocol envelope: OpenAI-compatible APIs contain one `error` object, while Anthropic Messages uses its `type: "error"` envelope. Structured provider message, type, code, status, and parameter fields are normalized and bounded without duplicate wrapper layers; headers, credentials, request bodies, tool arguments, internal Elixir terms, and synthetic inspected stream reasons are never forwarded. Circuit breakers move through closed, open, and half-open states per deployment.

## Built-in providers

- **OpenAI** — API-key authentication and OpenAI APIs.
- **Anthropic** — API-key authentication and Anthropic Messages.
- **OpenRouter** — OpenAI-compatible API with OpenRouter headers.
- **OpenAI Codex** — ChatGPT subscription Codex backend with OAuth credentials; streaming uses ReqLLM's Responses WebSocket transport.

Configuration-driven providers cover other ReqLLM adapters and OpenAI-compatible endpoints.

## OpenAI Codex OAuth

`openai-codex` uses provider-token records. Plain access tokens work until they expire. Refreshable seed entries use:

```text
access_token|refresh_token|expires_unix_ms|account_id
```

`account_id` is optional. Refreshed credentials are persisted as token, refresh token, expiry, and account ID.

For standalone services, prefer the live Incant admin action described in [Admin Integration](admin-integration.md). It runs against the active storage owner and persists refreshed credentials without starting a second database owner.

The release also includes `bin/codex_login` for local or manual recovery. If the release uses exclusive local storage, stop the service before using a separate-VM recovery command.

## Custom protocols

Implement `LLMProxy.Providers.Behaviour` only when the upstream needs a protocol or authentication flow ReqLLM cannot provide:

```elixir
defmodule MyApp.LLM.CustomProvider do
  @behaviour LLMProxy.Providers.Behaviour

  alias LLMProxy.Providers.Result

  def name, do: "custom"
  def native_protocol, do: :openai
  def models, do: ["custom-model"]

  def call(body, actor_id) do
    # Authenticate, execute, and return an explicit Result variant.
    {:ok, Result.response(%{"choices" => []}, nil)}
  end

  def stream(body, actor_id) do
    {:ok, Result.stream([], nil)}
  end

  def extract_usage(_response), do: LLMProxy.Usage.zero()
  def to_openai_response(response, _model), do: response
end
```

Use these modules when implementing an extension:

- `LLMProxy.Providers.Execution` — attempts, fallback, timeouts, telemetry, and circuit breakers.
- `LLMProxy.Providers.Result` — explicit response, stream, and error variants.
- `LLMProxy.Providers.HTTPResult` — HTTP result conversion and `Retry-After` parsing.
- `LLMProxy.TokenPool.Server` — credential selection and cooldowns.

Providers may implement `call_native/2` and `stream_native/2` for native Messages or Responses passthrough. Native calls still receive catalog routing, timeout, circuit-breaker, and retry-after behavior.

## Transport behavior

Configuration-driven providers use LLMProxy's normalized chat path, including conversation history, tools, reasoning deltas, streaming, and usage.

The ReqLLM Finch transport uses eight HTTP/1 pool shards with four connections each by default, allowing bounded concurrency for long-lived streams. Cowboy uses the provider receive timeout as its idle ceiling and resets the timer when data is sent. LLMProxy adds SSE comment heartbeats during upstream silence.

OpenAI Codex WebSocket setup has a finite configurable connection deadline (10 seconds by default). After the socket is established, LLMProxy does not impose a default transport receive deadline on model silence; pool checkout remains independently bounded. ReqLLM timeout errors retain `connect`, `receive`, `total`, or `stream_idle` phases in safe 504 error codes and messages. ReqLLM v1.18 does not automatically retry WebSocket connection failures, and LLMProxy does not retry a lazy stream after provider output becomes observable.

Named tool selection is canonicalized internally and rendered for the destination protocol: OpenAI Chat uses a nested function choice, OpenAI Responses uses a flat function choice through ReqLLM, and Anthropic Messages uses a tool choice. Unknown future choice variants remain unchanged for passthrough compatibility. Function tool definitions are likewise translated when fallback crosses these protocol boundaries.

Provider errors are projected onto canonical status, code, and message fields. Exception terms, stacktraces, request bodies, and upstream headers are not rendered to clients.

## Related guides

- [Library Mode](../introduction/library-mode.md)
- [Standalone Mode](../introduction/standalone-mode.md)
- [Governance and Observability](governance-and-observability.md)
- [Configuration Cheatsheet](../reference/configuration.cheatmd)
