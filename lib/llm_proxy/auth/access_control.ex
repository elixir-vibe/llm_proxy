defmodule LLMProxy.Auth.AccessControl do
  @moduledoc false

  def check_model_access(%{id: "master"}, _model), do: :ok
  def check_model_access(api_key, model), do: LLMProxy.Storage.check_model_access(api_key, model)
end
