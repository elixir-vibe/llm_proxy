defmodule LLMProxy.Routes.Helpers do
  @moduledoc false

  import Plug.Conn

  require Logger

  alias LLMProxy.Pricing
  alias LLMProxy.Storage
  alias LLMProxy.TokenPool.Server, as: TokenPool

  def track_usage(api_key, model, usage, opts \\ %{})
  def track_usage(%{id: "master"}, _model, _usage, _opts), do: :ok

  def track_usage(api_key, model, usage, opts) do
    cost_usd = Pricing.calculate_cost(model, usage)

    Storage.update_key_usage(api_key, %{
      input: usage.input_tokens,
      output: usage.output_tokens,
      cache_read: Map.get(usage, :cache_read_tokens, 0),
      cache_write: Map.get(usage, :cache_write_tokens, 0),
      cost_usd: cost_usd
    })

    Storage.record_usage(%{
      key_id: api_key.id,
      model: model,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      cache_read_tokens: Map.get(usage, :cache_read_tokens, 0),
      cache_write_tokens: Map.get(usage, :cache_write_tokens, 0),
      cost_usd: cost_usd,
      duration_ms: opts[:duration_ms],
      ttft_ms: opts[:ttft_ms],
      provider: opts[:provider],
      tags: opts[:tags],
      metadata: opts[:metadata],
      timestamp: DateTime.utc_now()
    })

    duration_str = if opts[:duration_ms], do: " #{opts[:duration_ms]}ms", else: ""
    Logger.info("Completed #{api_key.name} model=#{model} in=#{usage.input_tokens} out=#{usage.output_tokens} cost=$#{Float.round(cost_usd, 6)}#{duration_str}")
  end

  def extract_metadata(body) do
    case body["metadata"] do
      %{} = meta ->
        tags = meta["tags"] || []
        %{tags: tags, metadata: Map.delete(meta, "tags")}

      _ ->
        %{tags: nil, metadata: nil}
    end
  end

  def extract_text_parts(parts) do
    parts
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      text when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def check_model_access(%{id: "master"}, _model), do: :ok
  def check_model_access(api_key, model), do: Storage.check_model_access(api_key, model)

  def mark_rate_limited(token) do
    TokenPool.mark_rate_limited(token)
    Logger.warning("Token #{token.id} marked as rate-limited")
  end

  def log_user_message(api_key, model, route, extractor) when is_function(extractor, 0) do
    case extractor.() do
      "" -> :ok
      msg -> Storage.log_message(%{key_id: api_key.id, model: model, route: route, user_message: msg})
    end
  end

  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
