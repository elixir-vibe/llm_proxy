defmodule LLMProxy.HTTP.Routes.Moderations.Params do
  @moduledoc false

  @default_model "omni-moderation-latest"

  defmodule Create do
    @moduledoc false
    defstruct [:input, :model]

    @type t :: %__MODULE__{input: String.t() | [String.t()] | map() | [map()], model: String.t()}
  end

  @spec parse_create(map()) :: {:ok, Create.t()} | {:error, String.t()}
  def parse_create(%{"input" => input} = body) when is_binary(input) and input != "" do
    {:ok, %Create{input: input, model: model(body)}}
  end

  def parse_create(%{"input" => [_ | _] = input} = body) do
    {:ok, %Create{input: input, model: model(body)}}
  end

  def parse_create(%{"input" => %{} = input} = body) do
    {:ok, %Create{input: input, model: model(body)}}
  end

  def parse_create(_body), do: {:error, "input is required"}

  defp model(%{"model" => model}) when is_binary(model) and model != "", do: model
  defp model(_body), do: @default_model
end
