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

## Commit Messages

Use semantic commit messages:

- `feat:` new feature
- `fix:` bug fix
- `docs:` documentation only
- `refactor:` code change that neither fixes a bug nor adds a feature
- `test:` adding or updating tests
- `chore:` maintenance tasks
