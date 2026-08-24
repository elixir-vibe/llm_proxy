defmodule LLMProxy.Admin.Resources.APIKey.CreateInput do
  @moduledoc false

  @enforce_keys [:name]
  defstruct [:name, trace_requests: false, capture_content: false]

  @type t :: %__MODULE__{
          name: String.t(),
          trace_requests: boolean(),
          capture_content: boolean()
        }

  @spec from_assigns(map()) :: {:ok, t()} | {:error, String.t()}
  def from_assigns(assigns) when is_map(assigns) do
    with {:ok, name} <- fetch_name(assigns),
         {:ok, trace_requests} <- fetch_boolean(assigns, "trace_requests"),
         {:ok, capture_content} <- fetch_boolean(assigns, "capture_content") do
      {:ok,
       %__MODULE__{
         name: name,
         trace_requests: trace_requests,
         capture_content: capture_content
       }}
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

  defp fetch_boolean(assigns, field) do
    case Map.fetch(assigns, field) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, nil} -> {:ok, false}
      {:ok, _value} -> {:error, "#{field} must be boolean"}
      :error -> {:ok, false}
    end
  end
end
