defmodule LLMProxy.HTTP.Routes.PassthroughErrors do
  @moduledoc """
  Renders provider and policy errors for provider-passthrough HTTP routes.

  Route modules provide protocol-specific error serialization through a typed
  callbacks struct while this module owns common provider-error dispatch.
  """

  require Logger

  alias LLMProxy.Providers.Result

  defmodule Handlers do
    @moduledoc """
    Route callbacks used to render and classify passthrough-route errors.
    """

    @enforce_keys [:send_error, :provider_error_type, :on_provider_error]
    defstruct [:send_error, :provider_error_type, :on_provider_error]

    @type send_error :: (Plug.Conn.t(), pos_integer(), String.t(), String.t() -> Plug.Conn.t())
    @type provider_error_type :: (pos_integer() -> String.t())
    @type on_provider_error :: (Result.t() -> :ok)

    @type t :: %__MODULE__{
            send_error: send_error(),
            provider_error_type: provider_error_type(),
            on_provider_error: on_provider_error()
          }
  end

  @spec handlers(
          Handlers.send_error(),
          Handlers.provider_error_type(),
          Handlers.on_provider_error()
        ) ::
          Handlers.t()
  def handlers(send_error, provider_error_type, on_provider_error \\ fn _result -> :ok end)
      when is_function(send_error, 4) and is_function(provider_error_type, 1) and
             is_function(on_provider_error, 1) do
    %Handlers{
      send_error: send_error,
      provider_error_type: provider_error_type,
      on_provider_error: on_provider_error
    }
  end

  @spec send(Plug.Conn.t(), term(), Handlers.t()) :: Plug.Conn.t()
  def send(conn, reason, %Handlers{} = handlers) do
    case reason do
      {:provider, %Result{provider: provider} = result} ->
        handlers.on_provider_error.(result)
        send_provider_error(conn, provider, result, handlers)

      {:permission, reason} ->
        handlers.send_error.(conn, 403, "permission_error", reason)

      {:not_found, reason} ->
        handlers.send_error.(conn, 404, "not_found_error", reason)

      {:guardrail, reason} ->
        handlers.send_error.(conn, 403, "permission_error", inspect(reason))
    end
  end

  defp send_provider_error(
         conn,
         provider,
         %Result{error: error, status: status},
         %Handlers{} = handlers
       ) do
    Logger.error("#{provider.name()} error (#{status}): #{error}")
    handlers.send_error.(conn, status, handlers.provider_error_type.(status), error)
  end
end
