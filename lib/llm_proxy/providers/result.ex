defmodule LLMProxy.Providers.Result do
  @moduledoc false

  @type kind :: :response | :stream | :error

  @enforce_keys [:kind]
  defstruct [
    :kind,
    :response,
    :stream,
    :error,
    :status,
    :token,
    :retry_after_ms,
    :provider,
    :model
  ]

  @type t :: %__MODULE__{
          kind: kind(),
          response: map() | nil,
          stream: Enumerable.t() | nil,
          error: String.t() | nil,
          status: pos_integer() | nil,
          token: map() | nil,
          retry_after_ms: non_neg_integer() | nil,
          provider: module() | nil,
          model: String.t() | nil
        }

  @spec response(map(), map() | nil) :: t()
  def response(body, token) when is_map(body),
    do: %__MODULE__{kind: :response, response: body, token: token}

  @spec stream(Enumerable.t(), map() | nil) :: t()
  def stream(stream, token), do: %__MODULE__{kind: :stream, stream: stream, token: token}

  @spec error(String.t(), pos_integer(), map() | nil, keyword()) :: t()
  def error(error, status, token, opts \\ []) when is_binary(error) and is_integer(status) do
    %__MODULE__{
      kind: :error,
      error: error,
      status: status,
      token: token,
      retry_after_ms: opts[:retry_after_ms]
    }
  end

  @spec with_attempt({:ok, t()} | {:error, t()}, module(), String.t()) ::
          {:ok, t()} | {:error, t()}
  def with_attempt({state, %__MODULE__{} = result}, provider, model)
      when state in [:ok, :error] do
    {state, %{result | provider: provider, model: model}}
  end
end
