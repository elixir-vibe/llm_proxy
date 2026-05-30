defmodule LLMProxy.Protocol.Request.Error do
  @moduledoc false

  defstruct [:code, :message]

  @type t :: %__MODULE__{code: String.t(), message: String.t()}

  @spec new(String.t(), String.t()) :: t()
  def new(code, message), do: %__MODULE__{code: code, message: message}
end
