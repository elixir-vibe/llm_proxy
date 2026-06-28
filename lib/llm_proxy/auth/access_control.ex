defmodule LLMProxy.Auth.AccessControl do
  @moduledoc """
  Model-access authorization checks for authenticated API keys and the master key.
  """

  def check_model_access(%{id: "master"}, _model), do: :ok
  def check_model_access(api_key, model), do: LLMProxy.Storage.check_model_access(api_key, model)
end
