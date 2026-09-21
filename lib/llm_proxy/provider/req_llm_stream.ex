defmodule LLMProxy.Provider.ReqLLMStream do
  @moduledoc false

  alias LLMProxy.Protocol.OpenAI
  alias LLMProxy.Providers.Result
  alias LLMProxy.Stream.Event
  alias LLMProxy.Usage
  alias ReqLLM.Provider.Defaults, as: ReqLLMDefaults
  alias ReqLLM.StreamChunk

  @spec new(Result.t(), LLMDB.Model.t()) :: Enumerable.t()
  def new(
        %Result{kind: :stream, stream: stream, provider: provider, model: upstream_model},
        model
      ) do
    protocol = provider_protocol(provider)
    rendered_model = upstream_model || model.id

    Stream.transform(
      stream,
      fn -> nil end,
      fn event, error -> reduce_event(event, error, protocol, rendered_model, model) end,
      &finish_stream/1,
      fn _error -> :ok end
    )
  end

  defp reduce_event(_event, {:error, _reason} = error, _protocol, _upstream_model, _model),
    do: {[], error}

  defp reduce_event(event, nil, protocol, upstream_model, model) do
    case event_items(event, protocol, upstream_model, model) do
      {:error, reason} -> {[], {:error, reason}}
      chunks -> {chunks, nil}
    end
  end

  defp finish_stream(nil), do: {[], nil}
  defp finish_stream({:error, _reason} = error), do: {[error], nil}

  defp event_items(%Event{kind: :error} = event, _protocol, _upstream_model, _model) do
    {:error, error_reason(event)}
  end

  defp event_items(
         %Event{data: %{"error" => _error}} = event,
         _protocol,
         _upstream_model,
         _model
       ) do
    {:error, error_reason(event)}
  end

  defp event_items(%Event{} = event, protocol, upstream_model, model) do
    chunks =
      event.data
      |> OpenAI.stream_event(protocol, upstream_model)
      |> decode_openai_event(model)
      |> append_usage(event.usage)
      |> strip_terminal_markers()

    chunks
  end

  defp event_items(event, _protocol, _upstream_model, _model) do
    {:error, {:invalid_llm_proxy_stream_event, event}}
  end

  defp decode_openai_event(nil, _model), do: []

  defp decode_openai_event(data, model) when is_map(data) do
    ReqLLMDefaults.default_decode_stream_event(%{data: data}, model)
  end

  defp decode_openai_event(_data, _model), do: []

  defp append_usage(chunks, nil), do: chunks

  defp append_usage(chunks, %Usage{} = usage) do
    chunks ++ [StreamChunk.meta(%{usage: req_llm_usage(usage)})]
  end

  defp strip_terminal_markers(chunks) do
    Enum.map(chunks, fn
      %StreamChunk{type: :meta, metadata: metadata} = chunk ->
        %{chunk | metadata: metadata |> Map.delete(:terminal?) |> Map.delete("terminal?")}

      chunk ->
        chunk
    end)
  end

  defp req_llm_usage(%Usage{} = usage) do
    %{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      cache_read_tokens: usage.cache_read_tokens,
      cache_write_tokens: usage.cache_write_tokens,
      total_tokens: usage.input_tokens + usage.output_tokens
    }
  end

  defp error_reason(%Event{data: %{"error" => reason}}), do: reason
  defp error_reason(%Event{data: reason}), do: reason

  defp provider_protocol(provider) when is_atom(provider) do
    if function_exported?(provider, :native_protocol, 0),
      do: provider.native_protocol(),
      else: :openai
  end

  defp provider_protocol(_provider), do: :openai
end
