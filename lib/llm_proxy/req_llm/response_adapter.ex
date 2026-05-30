defmodule LLMProxy.ReqLLM.ResponseAdapter do
  @moduledoc false

  alias LLMProxy.Response
  alias ReqLLM.Message.ContentPart

  @spec from_response(Response.t()) :: ReqLLM.Response.t()
  def from_response(%Response{} = response) do
    body = response.body
    text = response_text(body)

    %ReqLLM.Response{
      id: body["id"] || "llm_proxy",
      model: response.model,
      context: response.request.messages,
      message: ReqLLM.Context.assistant([ContentPart.text(text)]),
      object: body,
      stream?: false,
      stream: nil,
      usage: usage_map(response.usage),
      finish_reason: finish_reason(body),
      provider_meta: %{provider: response.provider.name(), trace_id: response.trace_id},
      error: nil
    }
  end

  @spec error_status(term()) :: pos_integer()
  def error_status({:not_found, _}), do: 404
  def error_status({:permission, _}), do: 403
  def error_status({:missing_api_key, _}), do: 401
  def error_status({:invalid_api_key, _}), do: 401
  def error_status({:provider, %{status: status}}) when is_integer(status), do: status
  def error_status(_reason), do: 500

  defp response_text(%{"choices" => [%{"message" => %{"content" => text}} | _]})
       when is_binary(text),
       do: text

  defp response_text(%{"output_text" => text}) when is_binary(text), do: text
  defp response_text(_body), do: ""

  defp finish_reason(%{"choices" => [%{"finish_reason" => "stop"} | _]}), do: :stop
  defp finish_reason(%{"choices" => [%{"finish_reason" => "length"} | _]}), do: :length
  defp finish_reason(%{"choices" => [%{"finish_reason" => "tool_calls"} | _]}), do: :tool_calls
  defp finish_reason(%{"choices" => [%{"finish_reason" => nil} | _]}), do: nil
  defp finish_reason(_body), do: nil

  defp usage_map(usage) do
    %{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      cache_read_tokens: usage.cache_read_tokens,
      cache_write_tokens: usage.cache_write_tokens
    }
  end
end
