defmodule LLMProxy.RPC.Chat do
  @moduledoc "SafeRPC request for an LLMProxy chat completion."

  @type t :: %__MODULE__{
          messages: String.t() | list() | ReqLLM.Context.t(),
          model: String.t(),
          api_key: term(),
          actor: term(),
          stream: boolean() | nil,
          metadata: map() | nil,
          tags: list() | nil,
          tools: list() | nil,
          tool_choice: term(),
          max_tokens: pos_integer() | nil,
          temperature: number() | nil,
          top_p: number() | nil,
          stop: term()
        }

  defstruct [
    :messages,
    :model,
    :api_key,
    :actor,
    :stream,
    :metadata,
    :tags,
    :tools,
    :tool_choice,
    :max_tokens,
    :temperature,
    :top_p,
    :stop
  ]
end
