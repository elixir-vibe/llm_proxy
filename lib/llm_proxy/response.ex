defmodule LLMProxy.Response do
  @moduledoc false

  alias LLMProxy.Protocol.Request
  alias LLMProxy.Usage

  defstruct [
    :body,
    :provider_body,
    :provider,
    :model,
    :request,
    :trace_id,
    cache_hit: false,
    usage: Usage.zero()
  ]

  @type t :: %__MODULE__{
          body: map(),
          provider_body: map(),
          provider: module(),
          model: String.t(),
          request: Request.t(),
          trace_id: String.t() | nil,
          cache_hit: boolean(),
          usage: Usage.t()
        }
end
