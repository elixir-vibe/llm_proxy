if Code.ensure_loaded?(Incant) do
  defmodule LLMProxy.Admin.Policy do
    @moduledoc """
    Incant authorization policy for the LLMProxy admin surface.

    This is intentionally permissive while the unified `elixir.toys` admin route
    is still private/design-only. Keeping the policy explicit makes every admin
    action go through a named authorization boundary before the route is exposed.
    """

    use Incant.Policy

    @impl Incant.Policy
    def authorize(_action, _actor, _context), do: :ok
  end
end
