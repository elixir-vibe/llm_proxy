defmodule LLMProxy.Caches do
  @moduledoc false

  alias LLMProxy.Cache.{Key, Policy}
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
  def put(key, %Response{cacheable: true} = response, context) when is_binary(key) do
    context = put_policy(context, response)

    case adapter() do
      nil -> ignore()
      module -> put_response(module, key, response, context)
    end
  end

  def put(_key, %Response{}, _context), do: :ok

  @spec enabled?(Request.t(), LLMProxy.Cache.context()) :: boolean()
  def enabled?(%Request{stream: true}, _context), do: false

  def enabled?(%Request{} = request, context) do
    not is_nil(adapter()) and Policy.resolve(request, context).enabled
  end

  @spec policy(Request.t(), LLMProxy.Cache.context()) :: Policy.t()
  def policy(%Request{} = request, context), do: Policy.resolve(request, context)

  defp put_response(module, key, response, context) do
    if function_exported?(module, :put, 3) do
      case module.put(key, response, context) do
        :ok -> :ok
        _other -> :ok
      end
    else
      :ok
    end
  end

  defp put_policy(context, response) do
    context
    |> Map.put(:cache_ttl_ms, response.cache_ttl_ms)
    |> Map.put(:cacheable, response.cacheable)
  end

  defp adapter do
    Application.get_env(:llm_proxy, :cache)
  end

  defp ignore, do: :ok
end
