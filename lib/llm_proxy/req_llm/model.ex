defmodule LLMProxy.ReqLLM.Model do
  @moduledoc false

  @spec id(map() | String.t()) :: String.t()
  def id(%{model: model}) when is_binary(model), do: model
  def id(%{id: id}) when is_binary(id), do: id
  def id(model) when is_binary(model), do: model
end
