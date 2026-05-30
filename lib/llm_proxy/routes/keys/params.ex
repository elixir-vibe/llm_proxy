defmodule LLMProxy.Routes.Keys.Params do
  @moduledoc false

  @quota_fields %{
    "quota_4h_input" => :quota_4h_input,
    "quota_4h_output" => :quota_4h_output,
    "quota_week_input" => :quota_week_input,
    "quota_week_output" => :quota_week_output,
    "quota_4h_messages" => :quota_4h_messages,
    "quota_week_messages" => :quota_week_messages,
    "min_cache_ratio" => :min_cache_ratio
  }

  defmodule Generate do
    @moduledoc false
    defstruct [:name, opts: %{}]

    @type t :: %__MODULE__{name: String.t(), opts: map()}
  end

  defmodule Quota do
    @moduledoc false
    defstruct [:id, attrs: %{}]

    @type t :: %__MODULE__{id: String.t(), attrs: map()}
  end

  defmodule Models do
    @moduledoc false
    defstruct [:id, :allowed_models]

    @type t :: %__MODULE__{id: String.t(), allowed_models: [String.t()] | nil}
  end

  defmodule Delete do
    @moduledoc false
    defstruct [:id]

    @type t :: %__MODULE__{id: String.t()}
  end

  @spec parse_generate(map()) :: Generate.t()
  def parse_generate(body) do
    opts =
      body
      |> take_known_fields(@quota_fields)
      |> put_if_present(:allowed_models, body["allowed_models"])
      |> put_if_present(:service_quotas, body["service_quotas"])

    %Generate{name: body["name"] || "Unnamed", opts: opts}
  end

  @spec parse_quota(map()) :: {:ok, Quota.t()} | {:error, String.t()}
  def parse_quota(%{"id" => id} = body) when is_binary(id) and id != "" do
    attrs =
      body
      |> take_known_fields(@quota_fields)
      |> put_if_present(:service_quotas, body["service_quotas"])

    if attrs == %{} do
      {:error, "No quota fields provided"}
    else
      {:ok, %Quota{id: id, attrs: attrs}}
    end
  end

  def parse_quota(_body), do: {:error, "id is required"}

  @spec parse_models(map()) :: {:ok, Models.t()} | {:error, String.t()}
  def parse_models(%{"id" => id, "allowed_models" => allowed_models})
      when is_binary(id) and id != "" do
    {:ok, %Models{id: id, allowed_models: allowed_models}}
  end

  def parse_models(_body), do: {:error, "id and allowed_models are required"}

  @spec parse_delete(map()) :: {:ok, Delete.t()} | {:error, String.t()}
  def parse_delete(%{"id" => id}) when is_binary(id) and id != "" do
    {:ok, %Delete{id: id}}
  end

  def parse_delete(_body), do: {:error, "id is required"}

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp take_known_fields(body, fields) do
    Enum.reduce(fields, %{}, fn {json_key, field}, attrs ->
      if Map.has_key?(body, json_key), do: Map.put(attrs, field, body[json_key]), else: attrs
    end)
  end
end
