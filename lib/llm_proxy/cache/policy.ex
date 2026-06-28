defmodule LLMProxy.Cache.Policy do
  @moduledoc """
  Resolves configured and per-request cache policy into a strict runtime policy struct.
  """

  alias LLMProxy.Protocol.Request

  defstruct enabled: true, ttl_ms: nil

  @type t :: %__MODULE__{enabled: boolean(), ttl_ms: pos_integer() | nil}

  @spec resolve(Request.t(), map()) :: t()
  def resolve(%Request{} = request, context \\ %{}) do
    request
    |> configured_policy(context)
    |> apply_request_metadata(request)
  end

  defp configured_policy(%Request{model: model}, context) do
    :llm_proxy
    |> Application.get_env(:cache_policy, [])
    |> normalize_config()
    |> policy_for_model(model, context)
  end

  defp normalize_config(%__MODULE__{} = policy), do: %{default: policy, models: %{}}

  defp normalize_config(config) when is_list(config) do
    config
    |> Map.new()
    |> normalize_config()
  end

  defp normalize_config(config) when is_map(config) do
    %{
      default: policy(Map.get(config, :default) || Map.get(config, "default") || config),
      models: Map.get(config, :models) || Map.get(config, "models") || %{}
    }
  end

  defp normalize_config(_config), do: %{default: %__MODULE__{}, models: %{}}

  defp policy_for_model(%{default: default, models: models}, model, context) do
    model_policy = Map.get(models, model) || Map.get(models, context[:model])
    merge(default, policy(model_policy))
  end

  defp policy(nil), do: %__MODULE__{}
  defp policy(%__MODULE__{} = policy), do: policy
  defp policy(config) when is_list(config), do: config |> Map.new() |> policy()

  defp policy(config) when is_map(config) do
    %__MODULE__{
      enabled: get(config, :enabled, "enabled", true),
      ttl_ms: get(config, :ttl_ms, "ttl_ms", nil)
    }
  end

  defp policy(_config), do: %__MODULE__{}

  defp merge(%__MODULE__{} = default, %__MODULE__{} = override) do
    %__MODULE__{
      enabled: override.enabled,
      ttl_ms: override.ttl_ms || default.ttl_ms
    }
  end

  defp apply_request_metadata(%__MODULE__{} = policy, %Request{metadata: metadata})
       when is_map(metadata) do
    cond do
      metadata["cache"] == false -> %{policy | enabled: false}
      metadata["no_cache"] == true -> %{policy | enabled: false}
      is_integer(metadata["cache_ttl_ms"]) -> %{policy | ttl_ms: metadata["cache_ttl_ms"]}
      true -> policy
    end
  end

  defp apply_request_metadata(policy, _request), do: policy

  defp get(map, atom_key, string_key, default),
    do: Map.get(map, atom_key, Map.get(map, string_key, default))
end
