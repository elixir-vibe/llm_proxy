defmodule LLMProxy.Providers.ReplayPolicy do
  @moduledoc """
  Decides if a failed provider attempt can be replayed on another deployment.

  Safe failures prove that the upstream did not accept work. Uncertain failures
  can have billable or side-effecting work in progress. Forbidden failures are
  request or authorization failures that another deployment must not replay.
  """

  alias LLMProxy.Providers.Result

  @type policy :: :safe_only | :allow_uncertain
  @type decision :: {:retry | :stop, atom()}

  @spec decide(Result.t(), boolean(), boolean(), policy()) :: decision()
  def decide(_result, false, _budget_available, _policy), do: {:stop, :no_remaining_route}
  def decide(_result, _has_next, false, _policy), do: {:stop, :attempt_budget_exhausted}

  def decide(%Result{replay_safety: :safe}, true, true, _policy),
    do: {:retry, :safe_failure}

  def decide(%Result{replay_safety: :uncertain}, true, true, :allow_uncertain),
    do: {:retry, :uncertain_replay_enabled}

  def decide(%Result{replay_safety: :uncertain}, true, true, :safe_only),
    do: {:stop, :uncertain_replay_disabled}

  def decide(%Result{}, true, true, _policy), do: {:stop, :replay_forbidden}
end
