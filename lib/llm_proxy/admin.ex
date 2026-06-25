defmodule LLMProxy.Admin do
  @moduledoc """
  Service-owned Incant admin interface for LLMProxy.

  This module is the stable admin surface that can be described locally with
  `Incant.Admin.describe/1` and later exposed over SafeRPC.
  """

  use Incant.Admin,
    service: :llm_proxy,
    version: "1",
    repo: LLMProxy.Repo,
    policy: LLMProxy.Admin.Policy,
    rpc: true

  expose(LLMProxy.Schemas.ApiKey)
  expose(LLMProxy.Schemas.ProviderToken)
  expose(LLMProxy.Schemas.Trace, readonly: true)
  expose(LLMProxy.Schemas.MessageLog, as: :message, readonly: true)

  dashboard(LLMProxy.Admin.Dashboards.Operations)

  @rpc true
  @doc "Create an LLMProxy API key and return the one-time raw key."
  @spec create_api_key(map(), map(), term()) :: {:ok, map()} | {:error, term()}
  def create_api_key(payload, _meta, _state) when is_map(payload) do
    with {:ok, name} <- fetch_name(payload),
         {:ok, key, raw_key} <- LLMProxy.Storage.create_key(name, create_key_opts(payload)) do
      {:ok,
       %{
         id: key.id,
         name: key.name,
         api_key: raw_key,
         allowed_models: key.allowed_models,
         trace_requests: key.trace_requests
       }}
    end
  end

  defp fetch_name(payload) do
    case get_payload(payload, :name) do
      name when is_binary(name) and name != "" -> {:ok, name}
      _other -> {:error, :name_required}
    end
  end

  defp create_key_opts(payload) do
    %{}
    |> put_if_present(
      :allowed_models,
      normalize_allowed_models(get_payload(payload, :allowed_models))
    )
    |> put_if_present(:quota_4h_input, get_payload(payload, :quota_4h_input))
    |> put_if_present(:quota_4h_output, get_payload(payload, :quota_4h_output))
    |> put_if_present(:quota_week_input, get_payload(payload, :quota_week_input))
    |> put_if_present(:quota_week_output, get_payload(payload, :quota_week_output))
    |> put_if_present(:quota_4h_messages, get_payload(payload, :quota_4h_messages))
    |> put_if_present(:quota_week_messages, get_payload(payload, :quota_week_messages))
    |> put_if_present(:max_budget_usd, get_payload(payload, :max_budget_usd))
    |> put_if_present(:budget_period, get_payload(payload, :budget_period))
    |> put_if_present(:trace_requests, get_payload(payload, :trace_requests))
  end

  defp normalize_allowed_models(nil), do: nil
  defp normalize_allowed_models(models) when is_list(models), do: models

  defp normalize_allowed_models(models) when is_binary(models) do
    models
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp get_payload(payload, key), do: Map.get(payload, key) || Map.get(payload, to_string(key))
  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
