defmodule LLMProxy.ProviderUsage.Adapter do
  @moduledoc "Provider-specific boundary for live usage acquisition."

  alias LLMProxy.Provider.Credential
  alias LLMProxy.ProviderUsage.{Result, Source}

  @callback fetch(Credential.t(), Source.t()) ::
              {:ok, Result.t()} | {:error, term()}

  @doc false
  @spec parse_json(term(), module(), (term() -> {:ok, Result.t()} | {:error, term()})) ::
          {:ok, Result.t()} | {:error, term()}
  def parse_json(body, response_module, parser)
      when is_binary(body) and is_atom(response_module) and is_function(parser, 1) do
    case response_module.decode(body) do
      {:ok, response} -> parser.(response)
      {:error, reason} -> {:error, {:invalid_response, reason}}
    end
  end

  def parse_json(_body, _response_module, _parser), do: {:error, :invalid_response}

  @doc false
  @spec collect(Enumerable.t(), (term() -> {:ok, term() | nil} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  def collect(items, parser) when is_function(parser, 1) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, parsed} ->
      case parser.(item) do
        {:ok, nil} -> {:cont, {:ok, parsed}}
        {:ok, value} -> {:cont, {:ok, [value | parsed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_collected()
  end

  @doc false
  @spec percent(term(), atom()) :: {:ok, number()} | {:error, atom()}
  def percent(value, _error_reason) when is_number(value) and value >= 0 and value <= 100,
    do: {:ok, rounded(value)}

  def percent(_value, error_reason), do: {:error, error_reason}

  @doc false
  @spec remaining_percent(number()) :: number()
  def remaining_percent(used), do: rounded(100 - used)

  @doc false
  @spec plan(term()) :: {:ok, String.t() | nil} | {:error, :invalid_plan}
  def plan(nil), do: {:ok, nil}

  def plan(value) when is_binary(value) and byte_size(value) <= 40 do
    if Regex.match?(~r/^[[:alnum:]_-]+$/u, value) do
      {:ok, value}
    else
      {:error, :invalid_plan}
    end
  end

  def plan(_value), do: {:error, :invalid_plan}

  @doc false
  @spec valid_header_value?(term()) :: boolean()
  def valid_header_value?(value) when is_binary(value) and value != "" do
    not String.contains?(value, ["\r", "\n"])
  end

  def valid_header_value?(_value), do: false

  defp reverse_collected({:ok, parsed}), do: {:ok, Enum.reverse(parsed)}
  defp reverse_collected({:error, _reason} = error), do: error

  defp rounded(value) when is_integer(value), do: value
  defp rounded(value), do: Float.round(value, 1)
end
