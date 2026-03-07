defmodule LLMProxy.Providers.Anthropic do
  @moduledoc false

  @behaviour LLMProxy.Providers.Behaviour

  alias LLMProxy.Providers.Helpers

  @default_base_url "https://api.anthropic.com/v1"
  @api_version "2023-06-01"
  @beta "fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14"

  @models_path Path.join(:code.priv_dir(:llm_proxy), "models/anthropic.json")
  @external_resource @models_path
  @models @models_path |> File.read!() |> Jason.decode!()

  @impl true
  def name, do: "anthropic"

  @impl true
  def models, do: @models

  @impl true
  def call(body, user_id) do
    with {:ok, token} <- Helpers.pick_token("anthropic", user_id) do
      body |> to_anthropic_body() |> do_call(token)
    end
  end

  @impl true
  def stream(body, user_id) do
    with {:ok, token} <- Helpers.pick_token("anthropic", user_id) do
      body |> to_anthropic_body() |> Map.put("stream", true) |> do_stream(token)
    end
  end

  @impl true
  def call_native(body, user_id) do
    with {:ok, token} <- Helpers.pick_token("anthropic", user_id) do
      do_call(token, body)
    end
  end

  @impl true
  def stream_native(body, user_id) do
    with {:ok, token} <- Helpers.pick_token("anthropic", user_id) do
      body |> Map.put("stream", true) |> do_stream(token)
    end
  end

  @impl true
  def extract_usage(response) do
    usage = response["usage"] || %{}

    %{
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      cache_read_tokens: usage["cache_read_input_tokens"] || 0,
      cache_write_tokens: usage["cache_creation_input_tokens"] || 0
    }
  end

  @impl true
  def to_openai_response(response, model) do
    content = response["content"] || []
    {text, tool_calls} = extract_content_parts(content)
    message = build_openai_message(text, tool_calls)
    usage = build_openai_usage(response["usage"] || %{})

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

  # HTTP calls

  defp do_call(token, body) do
    req = Req.new(url: "#{base_url(token)}/messages", headers: headers(token), receive_timeout: 600_000) |> OpentelemetryReq.attach()

    case Req.post(req, json: body) do
      {:ok, %{status: 200, body: response}} -> {:ok, %{response: response, token: token}}
      {:ok, %{status: status, body: resp_body}} -> Helpers.handle_error_response(token, status, resp_body)
      {:error, exception} -> Helpers.handle_exception(exception)
    end
  end

  defp do_stream(body, token) do
    req =
      Req.new(url: "#{base_url(token)}/messages", headers: headers(token), into: :self, receive_timeout: 600_000)
      |> OpentelemetryReq.attach()

    case Req.post(req, json: body) do
      {:ok, %{status: 200} = resp} ->
        stream =
          resp.body
          |> Helpers.parse_sse_events()
          |> Stream.map(&to_stream_event/1)
          |> Stream.reject(&is_nil/1)

        {:ok, %{stream: stream, token: token}}

      {:ok, %{status: status, body: resp_body}} ->
        Helpers.handle_error_response(token, status, resp_body)

      {:error, exception} ->
        Helpers.handle_exception(exception)
    end
  end

  # Headers & URL

  defp headers(token) do
    [
      {"x-api-key", token.token},
      {"anthropic-version", @api_version},
      {"anthropic-beta", @beta},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]
  end

  defp base_url(%{proxy: proxy}) when is_binary(proxy) and proxy != "", do: proxy
  defp base_url(_token), do: @default_base_url

  # OpenAI → Anthropic conversion

  defp to_anthropic_body(body) do
    {system_msgs, other_msgs} = Enum.split_with(body["messages"] || [], &system?/1)

    base = %{
      "model" => body["model"],
      "messages" => Enum.map(other_msgs, &convert_message/1),
      "max_tokens" => body["max_tokens"] || 4096
    }

    base
    |> maybe_put_system(system_msgs)
    |> maybe_put_tools(body["tools"])
    |> maybe_put_temperature(body["temperature"])
  end

  defp system?(%{"role" => "system"}), do: true
  defp system?(_), do: false

  defp convert_message(%{"role" => "assistant", "tool_calls" => tool_calls} = msg) do
    text_blocks = build_assistant_text_blocks(msg["content"])
    tool_blocks = Enum.map(tool_calls, &convert_tool_call/1)

    %{"role" => "assistant", "content" => text_blocks ++ tool_blocks}
  end

  defp convert_message(%{"role" => "tool"} = msg) do
    %{
      "role" => "user",
      "content" => [
        %{
          "type" => "tool_result",
          "tool_use_id" => msg["tool_call_id"],
          "content" => msg["content"] || ""
        }
      ]
    }
  end

  defp convert_message(msg), do: msg

  defp build_assistant_text_blocks(nil), do: []
  defp build_assistant_text_blocks(""), do: []

  defp build_assistant_text_blocks(text) when is_binary(text) do
    [%{"type" => "text", "text" => text}]
  end

  defp build_assistant_text_blocks(_), do: []

  defp convert_tool_call(%{"function" => func} = tc) do
    %{
      "type" => "tool_use",
      "id" => tc["id"],
      "name" => func["name"],
      "input" => parse_arguments(func["arguments"])
    }
  end

  defp parse_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      {:error, _} -> %{}
    end
  end

  defp parse_arguments(args) when is_map(args), do: args
  defp parse_arguments(_), do: %{}

  defp maybe_put_system(body, []), do: body

  defp maybe_put_system(body, system_msgs) do
    system = Enum.map(system_msgs, fn msg -> %{"type" => "text", "text" => msg["content"]} end)
    Map.put(body, "system", system)
  end

  defp maybe_put_tools(body, nil), do: body
  defp maybe_put_tools(body, []), do: body

  defp maybe_put_tools(body, tools) do
    Map.put(body, "tools", Enum.map(tools, &convert_tool/1))
  end

  defp convert_tool(%{"function" => func} = _tool) do
    %{
      "name" => func["name"],
      "description" => func["description"] || "",
      "input_schema" => func["parameters"] || %{}
    }
  end

  defp convert_tool(tool), do: tool

  defp maybe_put_temperature(body, nil), do: body
  defp maybe_put_temperature(body, temp), do: Map.put(body, "temperature", temp)

  # Anthropic → OpenAI conversion

  defp extract_content_parts(content) do
    Enum.reduce(content, {"", []}, fn block, {text_acc, tools_acc} ->
      case block["type"] do
        "text" -> {join_text(text_acc, block["text"]), tools_acc}
        "tool_use" -> {text_acc, tools_acc ++ [to_openai_tool_call(block)]}
        _ -> {text_acc, tools_acc}
      end
    end)
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

  defp build_openai_message(text, []) do
    %{"role" => "assistant", "content" => text}
  end

  defp build_openai_message(text, tool_calls) do
    %{"role" => "assistant", "content" => text, "tool_calls" => tool_calls}
  end

  defp build_openai_usage(usage) do
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

  # Streaming

  defp to_stream_event(%{data: "[DONE]"}), do: nil

  defp to_stream_event(%{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, parsed} -> to_stream_event_from_map(parsed)
      {:error, _} -> nil
    end
  end

  defp to_stream_event(%{data: data}) when is_map(data) do
    to_stream_event_from_map(data)
  end

  defp to_stream_event(_), do: nil

  defp to_stream_event_from_map(%{"type" => "message_start", "message" => msg}) do
    event = %{data: %{"type" => "message_start", "message" => msg}}
    maybe_attach_usage(event, msg["usage"])
  end

  defp to_stream_event_from_map(%{"type" => "message_delta"} = parsed) do
    event = %{data: parsed}
    maybe_attach_usage(event, parsed["usage"])
  end

  defp to_stream_event_from_map(parsed) do
    %{data: parsed}
  end

  defp maybe_attach_usage(event, nil), do: event

  defp maybe_attach_usage(event, usage) do
    Map.put(event, :usage, %{
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      cache_read_tokens: usage["cache_read_input_tokens"] || 0,
      cache_write_tokens: usage["cache_creation_input_tokens"] || 0
    })
  end
end
