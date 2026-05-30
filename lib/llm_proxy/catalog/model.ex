defmodule LLMProxy.Catalog.Model do
  @moduledoc false

  alias LLMProxy.Catalog.Deployment

  defstruct [:name, hidden: false, deployments: [], metadata: %{}]

  @type t :: %__MODULE__{
          name: String.t(),
          hidden: boolean(),
          deployments: [Deployment.t()],
          metadata: map()
        }

  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      name: fetch!(attrs, :name, "name"),
      hidden: get(attrs, :hidden, "hidden", false),
      deployments: attrs |> get(:deployments, "deployments", []) |> Enum.map(&Deployment.new/1),
      metadata: get(attrs, :metadata, "metadata", %{})
    }
  end

  defp fetch!(attrs, atom_key, string_key) do
    Map.get(attrs, atom_key) || Map.fetch!(attrs, string_key)
  end

  defp get(attrs, atom_key, string_key, default) do
    Map.get(attrs, atom_key, Map.get(attrs, string_key, default))
  end
end
