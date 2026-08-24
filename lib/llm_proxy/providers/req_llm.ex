defmodule LLMProxy.Providers.ReqLLM do
  @moduledoc """
  Configuration-driven upstream provider backed by ReqLLM.

  A catalog route selects a named provider configuration. That configuration
  declares the ReqLLM adapter and base URL; the route selects an isolated token
  pool. No provider-specific Elixir module is required for endpoint or model-ID
  differences.
  """

  @behaviour LLMProxy.Providers.Behaviour

  alias Elixir.ReqLLM.{Context, StreamResponse, Tool}
  alias LLMProxy.Protocol.Request
  alias LLMProxy.Providers.{Attempt, Result}
  alias LLMProxy.Providers.ReqLLM.{ErrorProjection, Projection}
  alias LLMProxy.TokenPool.Server, as: TokenPool
  alias LLMProxy.Usage

  @request_option_keys ~w(max_tokens temperature top_p stop parallel_tool_calls)a
  @reasoning_efforts %{
    "none" => :none,
    "minimal" => :minimal,
    "low" => :low,
    "medium" => :medium,
    "high" => :high,
    "xhigh" => :xhigh,
    "max" => :max,
    "default" => :default
  }

  @impl true
  def name, do: "req-llm"

  @impl true
  def native_protocol, do: :openai

  @impl true
  def models, do: []

  @impl true
  def call(_body, _user_id), do: Result.unavailable_tokens(:missing_configured_attempt)

  def call(body, user_id, %Attempt{} = attempt) do
    with {:ok, token} <- pick_token(attempt, user_id) do
      call_with_token(body, attempt, token)
    end
  end

  @impl true
  def stream(_body, _user_id), do: Result.unavailable_tokens(:missing_configured_attempt)

  def stream(body, user_id, %Attempt{} = attempt) do
    with {:ok, token} <- pick_token(attempt, user_id) do
      stream_with_token(body, attempt, token)
    end
  end

  defp call_with_token(body, attempt, token) do
    with {:ok, model, context, opts} <- request(attempt, token, body),
         {:ok, response} <- ReqLLM.Generation.generate_text(model, context, opts) do
      {:ok, Result.response(Projection.response(response, attempt.model), token)}
    else
      {:error, reason} -> {:error, req_llm_error(reason, token, attempt.model)}
    end
  end

  defp stream_with_token(body, attempt, token) do
    with {:ok, model, context, opts} <- request(attempt, token, body),
         {:ok, response} <- ReqLLM.Generation.stream_text(model, context, opts) do
      stream =
        response
        |> StreamResponse.events()
        |> Stream.flat_map(&Projection.events(&1, attempt.model))

      {:ok, Result.stream(stream, token)}
    else
      {:error, reason} -> {:error, req_llm_error(reason, token, attempt.model)}
    end
  end

  @impl true
  def stream_error(reason, token), do: req_llm_error(reason, token, nil)

  @impl true
  def extract_usage(response) when is_map(response) do
    response
    |> Map.get("usage", %{})
    |> Usage.from_openai()
  end

  @impl true
  def to_openai_response(response, model), do: Map.put(response, "model", model)

  defp pick_token(
         %Attempt{provider_name: provider_name, token_pool: token_pool} = attempt,
         user_id
       ) do
    pool = token_pool || provider_name

    case TokenPool.pick_token(pool, user_id, attempt.model) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> Result.unavailable_tokens(reason)
    end
  end

  defp request(%Attempt{provider_name: provider_name, model: model_id}, token, body) do
    with {:ok, adapter} <- adapter(provider_name),
         {:ok, base_url} <- base_url(provider_name, token),
         {:ok, %Request{messages: messages}} <- Request.parse(:openai_chat, body) do
      model = %LLMDB.Model{
        id: model_id,
        model: model_id,
        provider: adapter,
        base_url: base_url
      }

      opts =
        [
          api_key: token.token,
          base_url: base_url,
          receive_timeout: LLMProxy.Config.provider_receive_timeout_ms()
        ]
        |> Keyword.merge(configured_req_options(provider_name))
        |> Keyword.merge(body_options(body))

      {:ok, model, %Context{messages: messages}, opts}
    end
  end

  defp adapter(provider_name) do
    configured = LLMProxy.Config.provider_value(provider_name, :adapter)
    adapter_name = configured |> to_string() |> String.replace("-", "_")

    case Enum.find(ReqLLM.Providers.list(), &(Atom.to_string(&1) == adapter_name)) do
      nil ->
        {:error, "unknown ReqLLM adapter for provider #{provider_name}"}

      adapter ->
        {:ok, adapter}
    end
  end

  defp base_url(_provider_name, %{proxy: proxy}) when is_binary(proxy) and proxy != "",
    do: {:ok, proxy}

  defp base_url(provider_name, _token) do
    case LLMProxy.Config.provider_value(provider_name, :base_url) do
      base_url when is_binary(base_url) and base_url != "" -> {:ok, base_url}
      _other -> {:error, "missing base_url for configured provider #{provider_name}"}
    end
  end

  defp configured_req_options(provider_name) do
    case LLMProxy.Config.provider_value(provider_name, :req_http_options) do
      options when is_list(options) -> [req_http_options: options]
      options when is_map(options) -> [req_http_options: Map.to_list(options)]
      _other -> []
    end
  end

  defp body_options(body) do
    options =
      Enum.reduce(@request_option_keys, [], fn key, acc ->
        case Map.fetch(body, Atom.to_string(key)) do
          {:ok, nil} -> acc
          {:ok, value} -> [{key, value} | acc]
          :error -> acc
        end
      end)

    options
    |> put_tools(body["tools"])
    |> put_tool_choice(body["tool_choice"])
    |> put_reasoning_effort(body["reasoning_effort"])
  end

  defp put_tools(options, tools) when is_list(tools) do
    Keyword.put(options, :tools, Enum.map(tools, &tool!/1))
  end

  defp put_tools(options, _tools), do: options

  defp tool!(%Tool{} = tool), do: tool

  defp tool!(%{"type" => "function", "function" => function}) do
    Tool.new!(
      name: Map.fetch!(function, "name"),
      description: function["description"] || "",
      parameter_schema: function["parameters"] || %{},
      strict: function["strict"] == true,
      callback: fn _arguments -> {:error, :execution_owned_by_client} end
    )
  end

  defp tool!(tool), do: raise(ArgumentError, "unsupported tool definition #{inspect(tool)}")

  defp put_tool_choice(options, nil), do: options

  defp put_tool_choice(options, choice) when choice in ["auto", "none", "required"],
    do: Keyword.put(options, :tool_choice, String.to_existing_atom(choice))

  defp put_tool_choice(options, choice), do: Keyword.put(options, :tool_choice, choice)

  defp put_reasoning_effort(options, nil), do: options

  defp put_reasoning_effort(options, effort) when is_atom(effort),
    do: put_reasoning_effort(options, Atom.to_string(effort))

  defp put_reasoning_effort(options, effort) when is_binary(effort) do
    case Map.fetch(@reasoning_efforts, effort) do
      {:ok, normalized} -> Keyword.put(options, :reasoning_effort, normalized)
      :error -> options
    end
  end

  defp req_llm_error(reason, token, model) do
    error = ErrorProjection.project(reason)

    if error.status == 429 do
      if is_binary(model),
        do: TokenPool.mark_rate_limited(token, model, LLMProxy.Config.token_cooldown_ms()),
        else: TokenPool.mark_rate_limited(token)
    end

    Result.error(error.message, error.status, token,
      replay_safety: ErrorProjection.replay_safety(reason),
      provider_body: %{"error" => ErrorProjection.client_error(reason)}
    )
  end
end
