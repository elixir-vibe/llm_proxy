defmodule LLMProxy.HTTP do
  @moduledoc """
  Req client factory that applies LLMProxy's HTTP instrumentation and test plug configuration.
  """

  def new(opts) do
    opts
    |> maybe_put_test_plug()
    |> Req.new()
    |> OpentelemetryReq.attach()
  end

  defp maybe_put_test_plug(opts) do
    case Application.get_env(:llm_proxy, :req_plug) do
      nil -> opts
      plug -> Keyword.put_new(opts, :plug, plug)
    end
  end
end
