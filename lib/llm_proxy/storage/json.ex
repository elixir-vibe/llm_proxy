defmodule LLMProxy.Storage.JSON do
  @moduledoc false

  use Ecto.Type

  def type, do: :string

  def cast(nil), do: {:ok, nil}
  def cast(value) when is_map(value) or is_list(value), do: {:ok, value}

  def cast(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> :error
    end
  end

  def cast(_value), do: :error

  def load(nil), do: {:ok, nil}

  def load(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> :error
    end
  end

  def load(value) when is_map(value) or is_list(value), do: {:ok, value}
  def load(_value), do: :error

  def dump(nil), do: {:ok, nil}

  def dump(value) when is_map(value) or is_list(value) do
    Jason.encode(value)
  end

  def dump(_value), do: :error
end
