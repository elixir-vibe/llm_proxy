defmodule LLMProxy.Cache.Runtime do
  @moduledoc """
  Runtime dispatcher for optional cache adapters, cache-key generation, and cache writes.
  """

  alias LLMProxy.Cache.Policy
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.Attempt
  alias LLMProxy.Response

  @spec key(Request.t(), [Attempt.t()]) :: String.t()
  def key(%Request{} = request, attempts) when is_list(attempts) do
    attempts = Enum.map(attempts, &attempt_key/1)

    :sha256
    |> :crypto.hash(:erlang.term_to_binary({request_key(request), attempts}))
    |> Base.url_encode64(padding: false)
  end

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

  @spec put(String.t(), Request.t(), Response.t(), LLMProxy.Cache.context()) :: :ok
  def put(key, %Request{} = request, %Response{cacheable: true} = response, context)
      when is_binary(key) do
    if enabled?(request, context) do
      context = put_policy(context, response)

      case adapter() do
        nil -> :ok
        module -> put_response(module, key, response, context)
      end
    else
      :ok
    end
  end

  def put(_key, %Request{}, %Response{}, _context), do: :ok

  @spec enabled?(Request.t(), LLMProxy.Cache.context()) :: boolean()
  def enabled?(%Request{stream: true}, _context), do: false

  def enabled?(%Request{} = request, context) do
    content_capture_enabled?(context) and not is_nil(adapter()) and
      Policy.resolve(request, context).enabled
  end

  @spec policy(Request.t(), LLMProxy.Cache.context()) :: Policy.t()
  def policy(%Request{} = request, context), do: Policy.resolve(request, context)

  defp request_key(%Request{} = request) do
    %{
      protocol: request.protocol,
      model: request.model,
      messages: request.messages,
      tools: request.tools,
      tool_choice: request.tool_choice,
      max_tokens: request.max_tokens,
      temperature: request.temperature,
      top_p: request.top_p,
      stop: request.stop
    }
  end

  defp attempt_key(%Attempt{provider: provider, model: model}) do
    {provider.name(), model}
  end

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

  defp content_capture_enabled?(%{api_key: %{capture_content: true}}), do: true
  defp content_capture_enabled?(_context), do: false

  defp put_policy(context, response) do
    context
    |> Map.put(:cache_ttl_ms, response.cache_ttl_ms)
    |> Map.put(:cacheable, response.cacheable)
  end

  defp adapter do
    Application.get_env(:llm_proxy, :cache)
  end
end
