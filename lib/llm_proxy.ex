defmodule LLMProxy do
  @moduledoc """
  OpenAI-compatible proxy for LLM APIs with usage tracking and per-user quotas.
  """

  use SafeRPC, service: :llm_proxy, version: "1", surface: :api

  alias LLMProxy.{Catalog, Provider, Response}
  alias LLMProxy.Protocol.Request

  @doc """
  Calls the proxy in-process using ReqLLM messages or a plain prompt.

  Pass either `:actor` with `%LLMProxy.Actor{}` or `:api_key` with an existing
  LLMProxy API key schema/map so quota and usage accounting can run.
  """
  defdelegate chat(messages, opts \\ []), to: Provider

  @rpc true
  @doc "List available models."
  @spec models(map(), map(), term()) :: {:ok, [map()]}
  def models(_payload, _meta, _state), do: {:ok, Catalog.all_models()}

  @rpc true
  @doc "Run a chat completion through LLMProxy."
  @spec chat(Request.t(), map(), term()) :: {:ok, Response.t()} | {:error, term()}
  def chat(%Request{} = request, meta, _state) when is_map(meta) do
    Provider.call(request, meta[:actor] || meta[:api_key], route: :safe_rpc)
  end

  @rpc surface: :control
  @doc "Return service status."
  @spec status(map(), map(), term()) :: {:ok, map()}
  def status(_payload, _meta, _state) do
    {:ok,
     %{
       service: :llm_proxy,
       version: application_version(),
       models: length(Catalog.all_models())
     }}
  end

  defp application_version do
    :llm_proxy
    |> Application.spec(:vsn)
    |> to_string()
  end
end
