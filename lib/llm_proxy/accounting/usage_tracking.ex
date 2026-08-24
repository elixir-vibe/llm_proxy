defmodule LLMProxy.Accounting.UsageTracking do
  @moduledoc """
  Usage accounting workflow for key counters, usage rows, optional traces, and optional content capture.
  """

  require Logger

  alias LLMProxy.Pricing
  alias LLMProxy.Storage
  alias LLMProxy.Telemetry
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
  rescue
    reason in [
      QuackDB.Error,
      DBConnection.ConnectionError,
      Ecto.ConstraintError,
      Ecto.QueryError,
      Ecto.StaleEntryError
    ] ->
      Telemetry.record_accounting_exception(
        to_string(opts[:provider] || "unknown"),
        model,
        trace_id(opts),
        reason,
        __STACKTRACE__
      )

      :ok
  end

  @spec maybe_record_trace(map(), String.t(), map(), map(), Usage.t(), map()) :: term()
  def maybe_record_trace(api_key, model, request_body, response_body, %Usage{} = usage, opts) do
    if Map.get(api_key, :trace_requests, false) do
      cost_usd = Pricing.calculate_cost(model, usage, opts[:provider])

      attrs = %{
        key_id: api_key.id,
        model: model,
        provider: opts[:provider],
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        cost_usd: cost_usd,
        duration_ms: opts[:duration_ms],
        ttft_ms: opts[:ttft_ms],
        tags: opts[:tags],
        metadata: opts[:metadata],
        session_id: get_in(opts, [:metadata, "session_id"]),
        timestamp: DateTime.utc_now()
      }

      attrs =
        if capture_content?(api_key) do
          Map.merge(attrs, %{
            request_body: Jason.encode!(request_body),
            response_body: Jason.encode!(response_body)
          })
        else
          attrs
        end

      Storage.record_trace(attrs)
    else
      :ok
    end
  end

  defp trace_id(%{metadata: %{"trace_id" => trace_id}}) when is_binary(trace_id), do: trace_id
  defp trace_id(_opts), do: "unknown"

  def log_user_message(api_key, model, route, extractor) when is_function(extractor, 0) do
    if capture_content?(api_key) do
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
    else
      :ok
    end
  end

  defp capture_content?(api_key), do: Map.get(api_key, :capture_content, false) == true
end
