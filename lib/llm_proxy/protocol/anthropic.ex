defmodule LLMProxy.Protocol.Anthropic do
  @moduledoc """
  Anthropic Messages API protocol.

  Handles conversion between Anthropic format and OpenAI format.
  """

  @behaviour LLMProxy.Protocol

  alias LLMProxy.Protocol.Request
  alias LLMProxy.Usage
  alias ReqLLM.Providers.Anthropic.Context, as: AnthropicContext

  @impl true
  def protocol, do: :anthropic

  @impl true
  def convert_response(response, :anthropic, _model), do: response
  def convert_response(response, :openai, model), do: to_anthropic_response(response, model)

  @impl true
  def extract_usage(response) do
    usage = response["usage"] || %{}

    Usage.from_anthropic(usage)
  end

  # --- OpenAI → Anthropic ---

  @spec request_body(Request.t(), keyword()) :: map()
  def request_body(request, opts \\ [])

  def request_body(
        %Request{protocol: :anthropic_messages, body: %{"messages" => _messages} = body} = request,
        opts
      ) do
    body
    |> Map.put("model", request.model)
    |> Map.put(
      "max_tokens",
      request.max_tokens || body["max_tokens"] || conversion_max_tokens(opts)
    )
    |> maybe_put_tools(request.tools)
    |> maybe_put("temperature", request.temperature)
    |> maybe_put("top_p", request.top_p)
    |> maybe_put("stream", request.stream)
    |> maybe_put("metadata", request.metadata)
    |> maybe_put("stop_sequences", request.stop)
    |> maybe_put("tool_choice", request.tool_choice)
  end

  def request_body(%Request{} = request, opts) do
    %ReqLLM.Context{messages: request.messages}
    |> AnthropicContext.encode_request(%{model: request.model})
    |> LLMProxy.Protocol.stringify_keys()
    |> Map.put("max_tokens", request.max_tokens || conversion_max_tokens(opts))
    |> maybe_put_tools(request.tools)
    |> maybe_put("temperature", request.temperature)
    |> maybe_put("top_p", request.top_p)
    |> maybe_put("stream", request.stream)
    |> maybe_put("metadata", request.metadata)
    |> maybe_put("stop_sequences", request.stop)
    |> maybe_put("tool_choice", request.tool_choice)
  end

  defp conversion_max_tokens(opts) do
    Keyword.get_lazy(opts, :max_tokens, fn ->
      LLMProxy.Config.provider_conversion_default("anthropic", :max_tokens)
    end)
  end

  defp build_assistant_text_blocks(nil), do: []
  defp build_assistant_text_blocks(""), do: []

  defp build_assistant_text_blocks(text) when is_binary(text),
    do: [%{"type" => "text", "text" => text}]

  defp build_assistant_text_blocks(_), do: []

  defp parse_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      {:error, _} -> %{}
    end
  end

  defp parse_arguments(args) when is_map(args), do: args
  defp parse_arguments(_), do: %{}

  defp maybe_put_tools(body, nil), do: body
  defp maybe_put_tools(body, []), do: body

  defp maybe_put_tools(body, tools) do
    Map.put(body, "tools", Enum.map(tools, &convert_tool_to_anthropic/1))
  end

  defp convert_tool_to_anthropic(%{"function" => func}) do
    %{
      "name" => func["name"],
      "description" => func["description"] || "",
      "input_schema" => func["parameters"] || %{}
    }
  end

  defp convert_tool_to_anthropic(tool), do: tool

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_anthropic_response(response, model) do
    choice = List.first(response["choices"] || []) || %{}
    message = choice["message"] || %{}

    %{
      "id" => response["id"] || "",
      "type" => "message",
      "role" => "assistant",
      "model" => model,
      "content" => openai_message_to_anthropic_content(message),
      "stop_reason" => map_finish_reason(choice["finish_reason"]),
      "usage" => openai_usage_to_anthropic(response["usage"] || %{})
    }
  end

  defp openai_message_to_anthropic_content(message) do
    text_blocks = build_assistant_text_blocks(message["content"])

    tool_blocks =
      Enum.map(message["tool_calls"] || [], fn tool_call ->
        %{
          "type" => "tool_use",
          "id" => tool_call["id"],
          "name" => get_in(tool_call, ["function", "name"]),
          "input" => parse_arguments(get_in(tool_call, ["function", "arguments"]))
        }
      end)

    text_blocks ++ tool_blocks
  end

  defp openai_usage_to_anthropic(usage) do
    %{
      "input_tokens" => usage["prompt_tokens"] || 0,
      "output_tokens" => usage["completion_tokens"] || 0
    }
  end

  defp map_finish_reason("tool_calls"), do: "tool_use"
  defp map_finish_reason("stop"), do: "end_turn"
  defp map_finish_reason("length"), do: "max_tokens"
  defp map_finish_reason(other), do: other
end
