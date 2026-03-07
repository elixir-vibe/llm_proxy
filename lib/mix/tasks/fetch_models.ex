defmodule Mix.Tasks.FetchModels do
  @shortdoc "Fetch model lists from models.dev and OpenRouter"
  @moduledoc "Downloads model catalogs and saves to priv/models/"

  use Mix.Task

  require Logger

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

  defp fetch_openrouter do
    Mix.shell().info("Fetching models from OpenRouter...")

    case Req.get(url: @openrouter_url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        ids =
          models
          |> Enum.filter(fn m ->
            "tools" in (m["supported_parameters"] || [])
          end)
          |> Enum.map(& &1["id"])
          |> Enum.sort()

        path = Path.join(@priv_dir, "openrouter.json")
        File.write!(path, Jason.encode!(ids, pretty: true))
        Mix.shell().info("  openrouter: #{length(ids)} models → #{path}")

      {:ok, %{status: status}} ->
        Mix.shell().error("OpenRouter returned #{status}")

      {:error, reason} ->
        Mix.shell().error("Failed to fetch OpenRouter models: #{inspect(reason)}")
    end
  end
end
