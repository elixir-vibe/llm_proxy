defmodule LLMProxy.HTTP.Routes.ModerationEndpoint.CreateRequest do
  @moduledoc """
  Parsed request body for the moderation endpoint.
  """

  @default_model "omni-moderation-latest"

  defstruct [:input, :model]

  @type t :: %__MODULE__{input: String.t() | [String.t()] | map() | [map()], model: String.t()}

  @spec parse(map()) :: {:ok, t()} | {:error, String.t()}
  def parse(%{"input" => input} = body) when is_binary(input) and input != "" do
    {:ok, %__MODULE__{input: input, model: model(body)}}
  end

  def parse(%{"input" => [_ | _] = input} = body) do
    {:ok, %__MODULE__{input: input, model: model(body)}}
  end

  def parse(%{"input" => %{} = input} = body) do
    {:ok, %__MODULE__{input: input, model: model(body)}}
  end

  def parse(_body), do: {:error, "input is required"}

  defp model(%{"model" => model}) when is_binary(model) and model != "", do: model
  defp model(_body), do: @default_model
end
