defmodule LLMProxy.Protocol.Anthropic do
  @moduledoc """
  Anthropic Messages API protocol.

  Handles conversion between Anthropic format and OpenAI format.
  """

  @behaviour LLMProxy.Protocol

  alias LLMProxy.Protocol.Request
  alias LLMProxy.Usage
  alias ReqLLM.Message
  alias ReqLLM.Message.{ContentPart, ReasoningDetails}
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
  def request_body(%Request{} = request, opts \\ []) do
    messages = prepare_anthropic_messages(request.messages)

    %ReqLLM.Context{messages: messages}
    |> AnthropicContext.encode_request(%{model: request.model})
    |> restore_redacted_thinking(request.messages)
    |> stringify_keys()
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

  defp prepare_anthropic_messages(messages) do
    Enum.map(messages, &prepare_anthropic_message/1)
  end

  defp prepare_anthropic_message(%Message{role: :assistant, content: content} = message) do
    {content, reasoning_details} = extract_reasoning_details(content)

    %{
      message
      | content: content,
        reasoning_details: append_reasoning_details(message.reasoning_details, reasoning_details)
    }
  end

  defp prepare_anthropic_message(%Message{} = message), do: message

  defp extract_reasoning_details(content) do
    content
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn
      {%ContentPart{type: :thinking, metadata: %{"redacted" => true}}, _index}, acc ->
        acc

      {%ContentPart{type: :thinking, text: text, metadata: metadata}, index},
      {content_acc, detail_acc} ->
        detail = %ReasoningDetails{
          text: text || "",
          signature: metadata["signature"],
          provider: :anthropic,
          index: index
        }

        {content_acc, [detail | detail_acc]}

      {part, _index}, {content_acc, detail_acc} ->
        {[part | content_acc], detail_acc}
    end)
    |> then(fn {content, details} -> {Enum.reverse(content), Enum.reverse(details)} end)
  end

  defp append_reasoning_details(nil, []), do: nil
  defp append_reasoning_details(nil, details), do: details
  defp append_reasoning_details(existing, []), do: existing
  defp append_reasoning_details(existing, details), do: existing ++ details

  defp restore_redacted_thinking(body, messages) do
    redacted_by_index = redacted_thinking_by_message_index(messages)

    update_in(body, [:messages], fn encoded_messages ->
      encoded_messages
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {message, index} ->
        restore_message_redacted_thinking(message, redacted_by_index[index])
      end)
    end)
  end

  defp redacted_thinking_by_message_index(messages) do
    messages
    |> Enum.reject(&(&1.role == :system))
    |> Enum.with_index()
    |> Map.new(fn {%Message{} = message, index} -> {index, redacted_thinking_blocks(message)} end)
    |> Map.reject(fn {_index, blocks} -> blocks == [] end)
  end

  defp redacted_thinking_blocks(%Message{role: :assistant, content: content}) do
    Enum.flat_map(content, fn
      %ContentPart{type: :thinking, metadata: %{"redacted" => true, "data" => data}} ->
        [%{type: "redacted_thinking", data: data}]

      _part ->
        []
    end)
  end

  defp redacted_thinking_blocks(%Message{}), do: []

  defp restore_message_redacted_thinking(message, nil), do: message

  defp restore_message_redacted_thinking(%{content: content} = message, redacted_blocks) do
    Map.put(message, :content, content_blocks(content) ++ redacted_blocks)
  end

  defp content_blocks(content) when is_list(content), do: content
  defp content_blocks(""), do: []
  defp content_blocks(content) when is_binary(content), do: [%{type: "text", text: content}]

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {string_key(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value), do: value

  defp string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp string_key(key), do: key

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
