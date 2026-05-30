defmodule LLMProxy.Actor do
  @moduledoc """
  Authenticated caller identity used below transport boundaries.
  """

  defstruct [:id, :name, :kind, :api_key, limits: %{}, metadata: %{}]

  @type kind :: :api_key | :user | :system | :master
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          kind: kind(),
          api_key: map() | nil,
          limits: map(),
          metadata: map()
        }

  @spec master_key :: map()
  def master_key do
    %{
      id: "master",
      name: "Master",
      quota_4h_input: nil,
      quota_4h_output: nil,
      quota_week_input: nil,
      quota_week_output: nil,
      quota_4h_messages: nil,
      quota_week_messages: nil,
      min_cache_ratio: nil,
      allowed_models: nil,
      service_quotas: nil
    }
  end

  @spec from_api_key(map()) :: t()
  def from_api_key(%{id: "master"} = api_key) do
    %__MODULE__{id: "master", name: Map.get(api_key, :name), kind: :master, api_key: api_key}
  end

  def from_api_key(%{id: id} = api_key) do
    %__MODULE__{
      id: to_string(id),
      name: Map.get(api_key, :name),
      kind: :api_key,
      api_key: api_key
    }
  end

  @spec system(keyword()) :: t()
  def system(opts \\ []) do
    %__MODULE__{
      id: to_string(Keyword.get(opts, :id, "system")),
      name: Keyword.get(opts, :name, "System"),
      kind: :system,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
