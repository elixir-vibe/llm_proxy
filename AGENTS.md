# LLM Proxy (Elixir)

OpenAI-compatible proxy for LLM APIs with usage tracking and per-user quotas.

## Development

```bash
mix setup       # Install deps + create DB + migrate
mix run --no-halt  # Start server
mix test        # Run tests
mix ci          # Full CI: compile, test, credo, dialyzer, ex_dna
mix format      # Format code
```

## Test Organization

Mirror `lib/` paths under `test/` where practical. Keep these test layers separate:

- Default unit and component tests live under `test/llm_proxy/` or `test/mix/`. They must be deterministic and must not require provider credentials or public network access.
- Integration tests live under `test/integration/` and use `@moduletag :integration`. They exercise one subsystem against a real dependency, such as a provider adapter calling its upstream API, while bypassing the public HTTP gateway.
- End-to-end tests live under `test/e2e/` and use `@moduletag :e2e`. They enter through a real HTTP listener and exercise the complete public request path, including authentication, routing, storage-backed token selection, provider execution, and HTTP response serialization.

Integration and end-to-end tests are opt-in because they may require credentials, network access, and billable provider calls. Do not mix direct-provider integration assertions and public-boundary end-to-end assertions in the same test module.

Run the layers independently:

```bash
mix test
mix integration
mix e2e
```

## Commit Messages

Use semantic commit messages:

- `feat:` new feature
- `fix:` bug fix
- `docs:` documentation only
- `refactor:` code change that neither fixes a bug nor adds a feature
- `test:` adding or updating tests
- `chore:` maintenance tasks
