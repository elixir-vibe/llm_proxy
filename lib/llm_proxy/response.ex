defmodule LLMProxy.Response do
  @moduledoc false

  alias LLMProxy.Protocol.Request
  alias LLMProxy.Usage

  defstruct [:body, :provider_body, :provider, :model, :request, usage: Usage.zero()]

  @type t :: %__MODULE__{
          body: map(),
          provider_body: map(),
          provider: module(),
          model: String.t(),
          request: Request.t(),
          usage: Usage.t()
        }
end
