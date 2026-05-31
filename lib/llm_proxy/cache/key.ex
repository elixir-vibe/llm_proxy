defmodule LLMProxy.Cache.Key do
  @moduledoc false

  alias LLMProxy.Protocol.Request
  alias LLMProxy.ProviderRouting.Attempt

  @spec build(Request.t(), [Attempt.t()]) :: String.t()
  def build(%Request{} = request, attempts) when is_list(attempts) do
    attempts = Enum.map(attempts, &attempt_key/1)

    :sha256
    |> :crypto.hash(:erlang.term_to_binary({request_key(request), attempts}))
    |> Base.url_encode64(padding: false)
  end

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
end
