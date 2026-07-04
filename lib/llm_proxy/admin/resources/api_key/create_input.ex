defmodule LLMProxy.Admin.Resources.APIKey.CreateInput do
  @moduledoc false

  @enforce_keys [:name]
  defstruct [:name, trace_requests: false]

  @type t :: %__MODULE__{name: String.t(), trace_requests: boolean()}

  @spec from_assigns(map()) :: {:ok, t()} | {:error, String.t()}
  def from_assigns(assigns) when is_map(assigns) do
    with {:ok, name} <- fetch_name(assigns),
         {:ok, trace_requests} <- fetch_trace_requests(assigns) do
      {:ok, %__MODULE__{name: name, trace_requests: trace_requests}}
    end
  end

  def from_assigns(_assigns), do: {:error, "Expected action assigns map"}

  defp fetch_name(%{"name" => name}) when is_binary(name) do
    name = String.trim(name)

    if name == "" do
      {:error, "Name is required"}
    else
      {:ok, name}
    end
  end

  defp fetch_name(%{}) do
    {:ok, "api-key"}
  end

  defp fetch_trace_requests(assigns) do
    case Map.fetch(assigns, "trace_requests") do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, nil} -> {:ok, false}
      {:ok, _value} -> {:error, "trace_requests must be boolean"}
      :error -> {:ok, false}
    end
  end
end
