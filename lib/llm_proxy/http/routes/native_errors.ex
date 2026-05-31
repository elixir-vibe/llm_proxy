defmodule LLMProxy.HTTP.Routes.NativeErrors do
  @moduledoc false

  require Logger

  alias LLMProxy.Providers.Result

  def send(
        conn,
        reason,
        send_error,
        provider_error_type,
        on_provider_error \\ fn _result -> :ok end
      ) do
    case reason do
      {:provider, %Result{provider: provider} = result} ->
        on_provider_error.(result)
        send_provider_error(conn, provider, result, send_error, provider_error_type)

      {:permission, reason} ->
        send_error.(conn, 403, "permission_error", reason)

      {:not_found, reason} ->
        send_error.(conn, 404, "not_found_error", reason)

      {:guardrail, reason} ->
        send_error.(conn, 403, "permission_error", inspect(reason))
    end
  end

  defp send_provider_error(
         conn,
         provider,
         %Result{error: error, status: status},
         send_error,
         type
       ) do
    Logger.error("#{provider.name()} error (#{status}): #{error}")
    send_error.(conn, status, type.(status), error)
  end
end
