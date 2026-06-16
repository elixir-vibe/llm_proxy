defmodule LLMProxy do
  @moduledoc """
  OpenAI-compatible proxy for LLM APIs with usage tracking and per-user quotas.
  """

  use SafeRPC, service: :llm_proxy, version: "1", surface: :api

  alias LLMProxy.{Catalog, ChatRequest, Provider, Response}

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
  @spec chat(ChatRequest.t(), map(), term()) :: {:ok, Response.t()} | {:error, term()}
  def chat(%ChatRequest{messages: nil}, _meta, _state),
    do: {:error, {:missing_required_field, :messages}}

  def chat(%ChatRequest{} = request, meta, _state) when is_map(meta) do
    Provider.chat(request.messages, rpc_chat_opts(request, meta))
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

  defp rpc_chat_opts(%ChatRequest{} = request, meta) do
    %{}
    |> put_option(:model, request.model)
    |> put_option(:api_key, request.api_key || meta[:api_key])
    |> put_option(:actor, request.actor || meta[:actor])
    |> put_option(:stream, request.stream)
    |> put_option(:metadata, request.metadata)
    |> put_option(:tags, request.tags)
    |> put_option(:tools, request.tools)
    |> put_option(:tool_choice, request.tool_choice)
    |> put_option(:max_tokens, request.max_tokens)
    |> put_option(:temperature, request.temperature)
    |> put_option(:top_p, request.top_p)
    |> put_option(:stop, request.stop)
    |> Map.to_list()
  end

  defp put_option(opts, _key, nil), do: opts
  defp put_option(opts, key, value), do: Map.put(opts, key, value)

  defp application_version do
    :llm_proxy
    |> Application.spec(:vsn)
    |> to_string()
  end
end
