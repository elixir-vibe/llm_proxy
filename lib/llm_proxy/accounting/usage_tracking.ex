defmodule LLMProxy.Accounting.UsageTracking do
  @moduledoc """
  Usage accounting workflow for key counters, usage rows, optional traces, and user-message logging.
  """

  require Logger

  alias LLMProxy.Pricing
  alias LLMProxy.Storage
  alias LLMProxy.Usage

  @spec track_usage(map(), String.t(), Usage.t(), map()) :: :ok | term()
  def track_usage(api_key, model, usage, opts \\ %{})
  def track_usage(%{id: "master"}, _model, %Usage{}, _opts), do: :ok

  def track_usage(api_key, model, %Usage{} = usage, opts) do
    cost_usd = Pricing.calculate_cost(model, usage, opts[:provider])

    Storage.update_key_usage(api_key, %{
      input: usage.input_tokens,
      output: usage.output_tokens,
      cache_read: usage.cache_read_tokens,
      cache_write: usage.cache_write_tokens,
      cost_usd: cost_usd
    })

    Storage.record_usage(%{
      key_id: api_key.id,
      model: model,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      cache_read_tokens: usage.cache_read_tokens,
      cache_write_tokens: usage.cache_write_tokens,
      cost_usd: cost_usd,
      duration_ms: opts[:duration_ms],
      ttft_ms: opts[:ttft_ms],
      provider: opts[:provider],
      tags: opts[:tags],
      metadata: opts[:metadata],
      timestamp: DateTime.utc_now()
    })

    if opts[:message_log_id] do
      Storage.update_message_usage(opts.message_log_id, %{
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens
      })
    end

    duration = if opts[:duration_ms], do: " #{opts[:duration_ms]}ms", else: ""

    Logger.info(
      "Completed #{api_key.name} model=#{model} in=#{usage.input_tokens} out=#{usage.output_tokens} cost=$#{Float.round(cost_usd, 6)}#{duration}"
    )
  end

  @spec maybe_record_trace(map(), String.t(), map(), map(), Usage.t(), map()) :: term()
  def maybe_record_trace(api_key, model, request_body, response_body, %Usage{} = usage, opts) do
    if Map.get(api_key, :trace_requests, false) do
      cost_usd = Pricing.calculate_cost(model, usage, opts[:provider])

      Storage.record_trace(%{
        key_id: api_key.id,
        model: model,
        provider: opts[:provider],
        request_body: Jason.encode!(request_body),
        response_body: Jason.encode!(response_body),
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        cost_usd: cost_usd,
        duration_ms: opts[:duration_ms],
        ttft_ms: opts[:ttft_ms],
        tags: opts[:tags],
        metadata: opts[:metadata],
        session_id: get_in(opts, [:metadata, "session_id"]),
        timestamp: DateTime.utc_now()
      })
    else
      :ok
    end
  end

  def log_user_message(api_key, model, route, extractor) when is_function(extractor, 0) do
    case extractor.() do
      "" ->
        :ok

      message ->
        Storage.log_message(%{
          key_id: api_key.id,
          model: model,
          route: route,
          user_message: message
        })
    end
  end
end
