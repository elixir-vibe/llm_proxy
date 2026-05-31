defmodule LLMProxy.Providers.Result do
  @moduledoc false

  defstruct response: nil,
            stream: nil,
            error: nil,
            status: nil,
            token: nil,
            retry_after_ms: nil,
            provider: nil,
            model: nil

  @type t :: %__MODULE__{
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
  def response(body, token), do: %__MODULE__{response: body, token: token}

  @spec stream(Enumerable.t(), map() | nil) :: t()
  def stream(stream, token), do: %__MODULE__{stream: stream, token: token}

  @spec error(String.t(), pos_integer(), map() | nil, keyword()) :: t()
  def error(error, status, token, opts \\ []) do
    %__MODULE__{error: error, status: status, token: token, retry_after_ms: opts[:retry_after_ms]}
  end

  @spec with_attempt({:ok, t()} | {:error, t()}, module(), String.t()) ::
          {:ok, t()} | {:error, t()}
  def with_attempt({state, %__MODULE__{} = result}, provider, model)
      when state in [:ok, :error] do
    {state, %{result | provider: provider, model: model}}
  end
end
