defmodule LLMProxy.Protocol.OpenAI do
  @moduledoc """
  OpenAI chat completion protocol.

  Handles conversion between OpenAI format and other protocols.
  """

  @behaviour LLMProxy.Protocol

  alias LLMProxy.Protocol.Request
  alias LLMProxy.Usage
  alias ReqLLM.Provider.Defaults, as: ReqLLMDefaults
  alias ReqLLM.Providers.OpenAI.AdapterHelpers

  @impl true
  def protocol, do: :openai

  @spec request_body(Request.t()) :: map()
  def request_body(%Request{
        protocol: :openai_chat,
        body: %{"messages" => _messages} = body,
        model: model
      }) do
    body
    |> normalize_openai_wire_response_format()
    |> Map.put("model", model)
  end

  def request_body(
        %Request{
          protocol: :openai_responses,
          body: %{"input" => input} = body,
          model: model
        } = request
      )
      when is_list(input) do
    body
    |> Map.take(["parallel_tool_calls", "response_format"])
    |> Map.put("messages", responses_input_to_openai_messages(input))
    |> Map.put("model", model)
    |> maybe_put("tools", openai_tools(request.tools))
    |> maybe_put("tool_choice", openai_tool_choice(request.tool_choice))
  end

  def request_body(%Request{} = request) do
    %ReqLLM.Context{messages: request.messages}
    |> ReqLLMDefaults.encode_context_to_openai_format(request.model)
    |> LLMProxy.Protocol.stringify_keys()
    |> Map.merge(Map.take(request.body, ["parallel_tool_calls", "response_format"]))
    |> Map.put("model", request.model)
    |> maybe_put("stream", request.stream)
    |> maybe_put("tools", openai_tools(request.tools))
    |> maybe_put("tool_choice", openai_tool_choice(request.tool_choice))
    |> maybe_put("max_tokens", request.max_tokens)
    |> maybe_put("temperature", request.temperature)
    |> maybe_put("top_p", request.top_p)
    |> maybe_put("stop", request.stop)
  end

  @impl true
  def convert_response(response, :openai, model) do
    Map.put(response, "model", model)
  end

  def convert_response(response, :anthropic, model) do
    anthropic_to_openai_response(response, model)
  end

  def stream_event(event, :openai, _model), do: event
  def stream_event(event, :anthropic, model), do: anthropic_stream_event(event, model)

  @impl true
  def extract_usage(response) do
    response
    |> Map.get("usage", %{})
    |> Usage.from_openai()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp openai_tool_choice(%{type: "tool", name: name}) when is_binary(name) do
    %{"type" => "function", "function" => %{"name" => name}}
  end

  defp openai_tool_choice("any"), do: "required"
  defp openai_tool_choice(tool_choice), do: tool_choice

  defp openai_tools(nil), do: nil
  defp openai_tools(tools) when is_list(tools), do: Enum.map(tools, &openai_tool/1)

  defp openai_tool(%{"type" => "function", "function" => %{} = _function} = tool),
    do: tool

  defp openai_tool(%{"type" => "function", "name" => name} = tool)
       when is_binary(name) do
    function =
      tool
      |> Map.take(["name", "description", "parameters"])
      |> Map.put_new("parameters", %{"type" => "object", "properties" => %{}})

    %{"type" => "function", "function" => function}
  end

  defp openai_tool(%{"name" => name, "input_schema" => schema} = tool)
       when is_binary(name) and is_map(schema) do
    function = %{"name" => name, "parameters" => schema}

    function =
      if is_binary(tool["description"]),
        do: Map.put(function, "description", tool["description"]),
        else: function

    %{"type" => "function", "function" => function}
  end

  defp openai_tool(tool), do: tool

  defp normalize_openai_wire_response_format(
         %{
           "response_format" =>
             %{
               "type" => "json_schema",
               "json_schema" => %{"strict" => true, "schema" => %{"type" => _type} = schema}
             } = response_format
         } = body
       ) do
    json_schema =
      Map.put(response_format["json_schema"], "schema", strict_openai_wire_schema(schema))

    Map.put(body, "response_format", %{response_format | "json_schema" => json_schema})
  end

  defp normalize_openai_wire_response_format(body), do: body

  defp strict_openai_wire_schema(schema) do
    %{response_format: %{"json_schema" => %{"schema" => schema}}} =
      AdapterHelpers.add_response_format(%{},
        response_format: %{
          "type" => "json_schema",
          "json_schema" => %{"strict" => true, "schema" => schema}
        }
      )

    schema
  end

  defp responses_input_to_openai_messages(input) do
    Enum.map(input, fn
      %{"role" => role, "content" => content} ->
        %{"role" => role, "content" => responses_content_to_openai(content)}

      item ->
        item
    end)
  end

  defp responses_content_to_openai(content) when is_list(content) do
    Enum.map(content, &responses_content_part_to_openai/1)
  end

  defp responses_content_to_openai(content), do: content

  defp responses_content_part_to_openai(%{"type" => "input_file", "file_id" => file_id})
       when is_binary(file_id) do
    %{"file" => %{"file_id" => file_id}}
  end

  defp responses_content_part_to_openai(%{
         "type" => "input_file",
         "filename" => filename,
         "file_data" => file_data
       }) do
    %{"file" => %{"filename" => filename, "file_data" => file_data}}
  end

  defp responses_content_part_to_openai(%{"type" => "input_text", "text" => text}) do
    %{"type" => "text", "text" => text}
  end

  defp responses_content_part_to_openai(
         %{"type" => "input_image", "image_url" => image_url} = part
       ) do
    image_url = if is_map(image_url), do: image_url, else: %{"url" => image_url}
    %{"type" => "image_url", "image_url" => Map.merge(image_url, Map.take(part, ["detail"]))}
  end

  defp responses_content_part_to_openai(part), do: part

  defp anthropic_stream_event(%{"type" => "message_start", "message" => message}, model) do
    chunk(message["id"], model, %{"role" => "assistant"})
  end

  defp anthropic_stream_event(
         %{"type" => "content_block_start", "index" => index, "content_block" => block},
         model
       ) do
    case block["type"] do
      "text" ->
        chunk(nil, model, %{"content" => block["text"] || ""})

      "tool_use" ->
        chunk(nil, model, %{
          "tool_calls" => [
            %{
              "index" => index,
              "id" => block["id"],
              "type" => "function",
              "function" => %{"name" => block["name"], "arguments" => ""}
            }
          ]
        })

      _ ->
        nil
    end
  end

  defp anthropic_stream_event(
         %{"type" => "content_block_delta", "index" => index, "delta" => delta},
         model
       ) do
    case delta["type"] do
      "text_delta" ->
        chunk(nil, model, %{"content" => delta["text"] || ""})

      "input_json_delta" ->
        chunk(nil, model, %{
          "tool_calls" => [
            %{"index" => index, "function" => %{"arguments" => delta["partial_json"] || ""}}
          ]
        })

      _ ->
        nil
    end
  end

  defp anthropic_stream_event(%{"type" => "message_delta", "delta" => delta}, model) do
    chunk(nil, model, %{}, map_stop_reason(delta["stop_reason"]))
  end

  defp anthropic_stream_event(%{"type" => "message_stop"}, _model), do: nil
  defp anthropic_stream_event(%{"type" => "content_block_stop"}, _model), do: nil
  defp anthropic_stream_event(_event, _model), do: nil

  defp chunk(id, model, delta, finish_reason \\ nil) do
    %{
      "id" => id || "",
      "object" => "chat.completion.chunk",
      "model" => model,
      "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish_reason}]
    }
  end

  defp anthropic_to_openai_response(response, model) do
    content = response["content"] || []
    {text, tool_calls} = extract_content_parts(content)
    message = build_message(text, tool_calls)
    usage = build_usage(response["usage"] || %{})

    %{
      "id" => response["id"] || "",
      "object" => "chat.completion",
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => message,
          "finish_reason" => map_stop_reason(response["stop_reason"])
        }
      ],
      "usage" => usage
    }
  end

  defp extract_content_parts(content) do
    {text, tools} =
      Enum.reduce(content, {"", []}, fn block, {text_acc, tools_acc} ->
        case block["type"] do
          "text" -> {join_text(text_acc, block["text"]), tools_acc}
          "tool_use" -> {text_acc, [to_openai_tool_call(block) | tools_acc]}
          _ -> {text_acc, tools_acc}
        end
      end)

    {text, Enum.reverse(tools)}
  end

  defp join_text("", new), do: new
  defp join_text(acc, new), do: acc <> "\n" <> new

  defp to_openai_tool_call(block) do
    %{
      "id" => block["id"],
      "type" => "function",
      "function" => %{
        "name" => block["name"],
        "arguments" => Jason.encode!(block["input"] || %{})
      }
    }
  end

  defp build_message(text, []), do: %{"role" => "assistant", "content" => text}

  defp build_message(text, tool_calls) do
    %{"role" => "assistant", "content" => text, "tool_calls" => tool_calls}
  end

  defp build_usage(usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0

    %{
      "prompt_tokens" => input,
      "completion_tokens" => output,
      "total_tokens" => input + output
    }
  end

  defp map_stop_reason("tool_use"), do: "tool_calls"
  defp map_stop_reason("end_turn"), do: "stop"
  defp map_stop_reason("max_tokens"), do: "length"
  defp map_stop_reason(other), do: other
end
