defmodule LLMProxy.RemoteProvider do
  @moduledoc """
  ReqLLM provider for calling a remote LLMProxy node over distributed Erlang.
  """

  use ReqLLM.Provider,
    id: :llm_proxy_remote,
    default_base_url: "erpc://llm_proxy_remote"

  alias LLMProxy.Provider
  alias LLMProxy.Remote
  alias LLMProxy.ReqLLM.Model
  alias LLMProxy.ReqLLM.ResponseAdapter

  @impl ReqLLM.Provider
  def prepare_request(:chat, model, messages, opts) do
    with {:ok, context} <- ReqLLM.Context.normalize(messages, opts),
         {:ok, request} <-
           Provider.chat_request(context, Keyword.put(opts, :model, Model.id(model))) do
      req =
        Req.new()
        |> Req.Request.prepend_request_steps(llm_proxy_remote_provider: &run_req_llm/1)
        |> Req.Request.put_private(:llm_proxy_remote_request, request)
        |> Req.Request.put_private(:llm_proxy_remote_opts, opts)

      {:ok, req}
    end
  end

  def prepare_request(operation, _model, _data, _opts) do
    {:error, ArgumentError.exception("LLMProxy remote provider does not support #{operation}")}
  end

  @impl ReqLLM.Provider
  def attach(request, _model, _opts), do: request

  @impl ReqLLM.Provider
  def encode_body(request), do: request

  @impl ReqLLM.Provider
  def build_body(_request), do: %{}

  @impl ReqLLM.Provider
  def decode_response(request_response), do: request_response

  defp run_req_llm(req_request) do
    request = Req.Request.get_private(req_request, :llm_proxy_remote_request)
    opts = Req.Request.get_private(req_request, :llm_proxy_remote_opts, [])
    node = Keyword.get(opts, :node) || Keyword.fetch!(opts, :llm_proxy_node)
    actor = Keyword.get(opts, :llm_proxy_actor) || Keyword.get(opts, :actor)
    api_key = Keyword.get(opts, :llm_proxy_api_key) || Keyword.get(opts, :api_key)

    remote_opts =
      opts
      |> Keyword.take([:remote_timeout, :trace_id, :usage_metadata])
      |> Keyword.put(:route, :req_llm_remote)

    case Remote.call(node, request, actor || api_key, remote_opts) do
      {:ok, response} ->
        req_llm_response = ResponseAdapter.from_response(response)
        Req.Request.halt(req_request, Req.Response.new(status: 200, body: req_llm_response))

      {:error, reason} ->
        Req.Request.halt(
          req_request,
          Req.Response.new(status: ResponseAdapter.error_status(reason), body: inspect(reason))
        )
    end
  end
end
