defmodule Mix.Tasks.FetchModels do
  @shortdoc "Fetch model lists from models.dev and OpenRouter"
  @moduledoc "Downloads model catalogs and saves to priv/models/"

  use Mix.Task

  @models_dev_url "https://models.dev/api.json"
  @openrouter_url "https://openrouter.ai/api/v1/models"
  @priv_dir "priv/models"

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    Application.ensure_all_started(:req)
    File.mkdir_p!(@priv_dir)

    fetch_models_dev()
    fetch_openrouter()

    Mix.shell().info("Models fetched successfully")
  end

  defp fetch_models_dev do
    Mix.shell().info("Fetching models from models.dev...")

    case Req.get(url: @models_dev_url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: data}} when is_map(data) ->
        save_provider_models(data, "anthropic")
        save_provider_models(data, "openai")
        save_pricing(data)

      {:ok, %{status: status}} ->
        Mix.shell().error("models.dev returned #{status}")

      {:error, reason} ->
        Mix.shell().error("Failed to fetch models.dev: #{inspect(reason)}")
    end
  end

  defp save_provider_models(data, provider) do
    models =
      data
      |> get_in([provider, "models"])
      |> case do
        nil ->
          []

        models_map ->
          models_map
          |> Enum.filter(fn {_id, m} -> m["tool_call"] == true end)
          |> Enum.map(fn {id, _m} -> id end)
          |> Enum.sort()
      end

    path = Path.join(@priv_dir, "#{provider}.json")
    File.write!(path, Jason.encode!(models, pretty: true))
    Mix.shell().info("  #{provider}: #{length(models)} models → #{path}")
  end

  defp save_pricing(data) do
    pricing =
      for {_provider, %{"models" => models}} <- data,
          {model_id, %{"cost" => cost}} when is_map(cost) <- models,
          into: %{} do
        entry = %{
          "input" => cost["input"] || 0,
          "output" => cost["output"] || 0,
          "cache_read" => cost["cache_read"] || 0,
          "cache_write" => cost["cache_write"] || 0
        }

        {model_id, entry}
      end

    path = Path.join(@priv_dir, "pricing.json")
    File.write!(path, Jason.encode!(pricing, pretty: true))
    Mix.shell().info("  pricing: #{map_size(pricing)} models → #{path}")
  end

  defp fetch_openrouter do
    Mix.shell().info("Fetching models from OpenRouter...")

    case Req.get(url: @openrouter_url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        tool_models =
          models
          |> Enum.filter(fn m ->
            "tools" in (m["supported_parameters"] || [])
          end)

        ids = tool_models |> Enum.map(& &1["id"]) |> Enum.sort()

        path = Path.join(@priv_dir, "openrouter.json")
        File.write!(path, Jason.encode!(ids, pretty: true))
        Mix.shell().info("  openrouter: #{length(ids)} models → #{path}")

        merge_openrouter_pricing(models)

      {:ok, %{status: status}} ->
        Mix.shell().error("OpenRouter returned #{status}")

      {:error, reason} ->
        Mix.shell().error("Failed to fetch OpenRouter models: #{inspect(reason)}")
    end
  end

  defp merge_openrouter_pricing(models) do
    pricing_path = Path.join(@priv_dir, "pricing.json")

    existing =
      case File.read(pricing_path) do
        {:ok, data} -> Jason.decode!(data)
        {:error, _} -> %{}
      end

    or_pricing =
      for %{"id" => id, "pricing" => pricing} <- models,
          is_map(pricing),
          into: %{} do
        prompt = parse_price(pricing["prompt"])
        completion = parse_price(pricing["completion"])
        cache_read = parse_price(pricing["input_cache_read"])

        entry = %{
          "input" => prompt * 1_000_000,
          "output" => completion * 1_000_000,
          "cache_read" => cache_read * 1_000_000,
          "cache_write" => 0
        }

        {id, entry}
      end

    merged = Map.merge(or_pricing, existing)
    File.write!(pricing_path, Jason.encode!(merged, pretty: true))

    new_count = map_size(merged) - map_size(existing)
    Mix.shell().info("  pricing: +#{new_count} from OpenRouter (#{map_size(merged)} total)")
  end

  defp parse_price(nil), do: 0.0
  defp parse_price(val) when is_number(val), do: val / 1

  defp parse_price(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end
