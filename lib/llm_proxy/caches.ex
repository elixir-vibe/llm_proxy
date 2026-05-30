defmodule LLMProxy.Caches do
  @moduledoc false

  alias LLMProxy.Cache.Key
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Response
  alias LLMProxy.Routing.Attempt

  @spec key(Request.t(), [Attempt.t()]) :: String.t()
  def key(%Request{} = request, attempts), do: Key.build(request, attempts)

  @spec get(String.t(), LLMProxy.Cache.context()) :: {:hit, Response.t()} | :miss
  def get(key, context) when is_binary(key) do
    case adapter() do
      nil ->
        :miss

      module ->
        case module.get(key, context) do
          {:hit, %Response{} = response} -> {:hit, response}
          _other -> :miss
        end
    end
  end

  @spec put(String.t(), Response.t(), LLMProxy.Cache.context()) :: :ok
  def put(key, %Response{} = response, context) when is_binary(key) do
    case adapter() do
      nil -> ignore()
      module -> put_response(module, key, response, context)
    end
  end

  @spec enabled?(Request.t()) :: boolean()
  def enabled?(%Request{stream: true}), do: false
  def enabled?(%Request{}), do: not is_nil(adapter())

  defp put_response(module, key, response, context) do
    case module.put(key, response, context) do
      :ok -> :ok
      _other -> :ok
    end
  end

  defp adapter do
    Application.get_env(:llm_proxy, :cache)
  end

  defp ignore, do: :ok
end
