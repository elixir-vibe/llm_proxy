defmodule LLMProxy.GuardrailPipeline do
  @moduledoc """
  Runs configured `LLMProxy.Guardrail` callbacks around requests, responses, and stream events.
  """

  alias LLMProxy.Protocol.Request
  alias LLMProxy.Response
  alias LLMProxy.Stream.Event

  @spec before_request(Request.t(), LLMProxy.Guardrail.context()) ::
          {:ok, Request.t()} | {:error, term()}
  def before_request(%Request{} = request, context) do
    run(:before_request, request, context)
  end

  @spec after_response(Response.t(), LLMProxy.Guardrail.context()) ::
          {:ok, Response.t()} | {:error, term()}
  def after_response(%Response{} = response, context) do
    run(:after_response, response, context)
  end

  @spec on_stream_event(Event.t(), LLMProxy.Guardrail.context()) ::
          {:ok, Event.t() | nil} | {:error, term()}
  def on_stream_event(%Event{} = event, context) do
    run(:on_stream_event, event, context)
  end

  defp run(callback, value, context) do
    Enum.reduce_while(guardrails(), {:ok, value}, fn guardrail, {:ok, current} ->
      guardrail
      |> apply_guardrail(callback, current, context)
      |> reduce_result()
    end)
  end

  defp apply_guardrail(guardrail, callback, current, context) do
    if function_exported?(guardrail, callback, 2),
      do: apply(guardrail, callback, [current, context]),
      else: {:ok, current}
  end

  defp reduce_result({:ok, updated}), do: {:cont, {:ok, updated}}
  defp reduce_result({:error, reason}), do: {:halt, {:error, reason}}

  defp guardrails do
    :llm_proxy
    |> Application.get_env(:guardrails, [])
    |> List.wrap()
  end
end
