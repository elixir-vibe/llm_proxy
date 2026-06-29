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
      |> reduce_result(callback)
    end)
  end

  defp apply_guardrail(guardrail, callback, current, context) do
    if function_exported?(guardrail, callback, 2),
      do: apply(guardrail, callback, [current, context]),
      else: {:ok, current}
  end

  defp reduce_result({:ok, nil}, :on_stream_event), do: {:halt, {:ok, nil}}
  defp reduce_result({:ok, updated}, _callback), do: {:cont, {:ok, updated}}
  defp reduce_result({:error, reason}, _callback), do: {:halt, {:error, reason}}

  defp guardrails do
    :llm_proxy
    |> Application.get_env(:guardrails, [])
    |> List.wrap()
    |> Enum.map(&validate_guardrail!/1)
  end

  defp validate_guardrail!(guardrail) when is_atom(guardrail), do: guardrail

  defp validate_guardrail!(guardrail) do
    raise ArgumentError, "guardrails must be module atoms, got: #{inspect(guardrail)}"
  end
end
