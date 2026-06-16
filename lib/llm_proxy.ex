defmodule LLMProxy do
  @moduledoc """
  OpenAI-compatible proxy for LLM APIs with usage tracking and per-user quotas.
  """

  use SafeRPC, service: :llm_proxy, version: "1", surface: :api

  alias LLMProxy.{Catalog, Provider, Response}

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
  @spec chat(map(), map(), term()) :: {:ok, Response.t()} | {:error, term()}
  def chat(payload, meta, _state) when is_map(payload) and is_map(meta) do
    with {:ok, messages} <- rpc_messages(payload) do
      Provider.chat(messages, rpc_chat_opts(payload, meta))
    end
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

  @rpc surface: :control
  @doc "Describe LLMProxy's Incant admin surface."
  @spec incant_describe(map(), map(), term()) :: {:ok, Incant.Admin.Contract.t()}
  def incant_describe(_payload, _meta, _state), do: {:ok, Incant.Admin.describe(LLMProxy.Admin)}

  defp rpc_messages(payload) do
    case get_in_payload(payload, [:messages, "messages", :prompt, "prompt"]) do
      nil -> {:error, {:missing_required_field, :messages}}
      messages -> {:ok, messages}
    end
  end

  defp rpc_chat_opts(payload, meta) do
    %{}
    |> put_option(:model, get_in_payload(payload, [:model, "model"]))
    |> put_option(
      :api_key,
      get_in_payload(payload, [:api_key, "api_key"]) || meta[:api_key] || meta["api_key"]
    )
    |> put_option(
      :actor,
      get_in_payload(payload, [:actor, "actor"]) || meta[:actor] || meta["actor"]
    )
    |> put_option(:stream, get_in_payload(payload, [:stream, "stream"]))
    |> put_option(:metadata, get_in_payload(payload, [:metadata, "metadata"]))
    |> put_option(:tags, get_in_payload(payload, [:tags, "tags"]))
    |> put_option(:tools, get_in_payload(payload, [:tools, "tools"]))
    |> put_option(:tool_choice, get_in_payload(payload, [:tool_choice, "tool_choice"]))
    |> put_option(:max_tokens, get_in_payload(payload, [:max_tokens, "max_tokens"]))
    |> put_option(:temperature, get_in_payload(payload, [:temperature, "temperature"]))
    |> put_option(:top_p, get_in_payload(payload, [:top_p, "top_p"]))
    |> put_option(:stop, get_in_payload(payload, [:stop, "stop"]))
    |> Map.to_list()
  end

  defp put_option(opts, _key, nil), do: opts
  defp put_option(opts, key, value), do: Map.put(opts, key, value)

  defp get_in_payload(payload, keys) do
    Enum.find_value(keys, &Map.get(payload, &1))
  end

  defp application_version do
    :llm_proxy
    |> Application.spec(:vsn)
    |> to_string()
  end
end
