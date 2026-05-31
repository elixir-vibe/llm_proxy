defmodule LLMProxy.Remote do
  @moduledoc """
  Distributed Erlang wrapper around `LLMProxy.Provider`.

  This module keeps `LLMProxy.Provider` as the execution boundary while allowing
  clients on another BEAM node to call it through `:erpc`.
  """

  alias LLMProxy.Actor
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Provider
  alias LLMProxy.Response

  @type node_ref :: node()

  @spec chat(node_ref(), String.t() | list() | ReqLLM.Context.t(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def chat(node, messages, opts \\ []) when is_atom(node) do
    {timeout, opts} = Keyword.pop(opts, :remote_timeout, LLMProxy.Config.remote_timeout_ms())
    :erpc.call(node, Provider, :chat, [messages, opts], timeout)
  end

  @spec call(node_ref(), Request.t(), Actor.t() | map() | String.t(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def call(node, %Request{} = request, actor_or_key, opts \\ []) when is_atom(node) do
    {timeout, opts} = Keyword.pop(opts, :remote_timeout, LLMProxy.Config.remote_timeout_ms())
    :erpc.call(node, Provider, :call, [request, actor_or_key, opts], timeout)
  end
end
