defmodule LLMProxy.HTTP.Routes.Passthrough do
  @moduledoc """
  Shared provider-passthrough route flow.

  Passthrough routes keep the upstream provider API shape at the HTTP boundary
  while sharing common result dispatch and provider-error dispatch here.
  """

  require Logger

  alias LLMProxy.ConcurrencyLimiter
  alias LLMProxy.HTTP.ErrorResponse
  alias LLMProxy.Providers.Result

  defmodule ResultHandler do
    @moduledoc """
    Route callbacks used to render passthrough non-streaming and streaming results.
    """

    @enforce_keys [:non_stream, :stream]
    defstruct [:non_stream, :stream]

    @type non_stream :: (Plug.Conn.t(), module(), map(), map(), String.t(), String.t() ->
                           Plug.Conn.t())

    @type stream :: (Plug.Conn.t(),
                     module(),
                     Enumerable.t(),
                     map(),
                     String.t(),
                     map()
                     | nil,
                     String.t() ->
                       Plug.Conn.t())

    @type t :: %__MODULE__{non_stream: non_stream(), stream: stream()}
  end

  defmodule ErrorHandler do
    @moduledoc """
    Route callbacks used to render and classify passthrough-route errors.
    """

    @enforce_keys [:send_error, :provider_error_type, :on_provider_error]
    defstruct [:send_error, :provider_error_type, :on_provider_error]

    @type send_error :: (Plug.Conn.t(), pos_integer(), String.t(), term() -> Plug.Conn.t())
    @type provider_error_type :: (pos_integer() -> String.t())
    @type on_provider_error :: (Result.t() -> :ok)

    @type t :: %__MODULE__{
            send_error: send_error(),
            provider_error_type: provider_error_type(),
            on_provider_error: on_provider_error()
          }
  end

  @spec result_handler(ResultHandler.non_stream(), ResultHandler.stream()) :: ResultHandler.t()
  def result_handler(non_stream, stream)
      when is_function(non_stream, 6) and is_function(stream, 7) do
    %ResultHandler{non_stream: non_stream, stream: stream}
  end

  @spec error_handler(
          ErrorHandler.send_error(),
          ErrorHandler.provider_error_type(),
          ErrorHandler.on_provider_error()
        ) :: ErrorHandler.t()
  def error_handler(send_error, provider_error_type, on_provider_error \\ fn _result -> :ok end)
      when is_function(send_error, 4) and is_function(provider_error_type, 1) and
             is_function(on_provider_error, 1) do
    %ErrorHandler{
      send_error: send_error,
      provider_error_type: provider_error_type,
      on_provider_error: on_provider_error
    }
  end

  @spec send_result(Plug.Conn.t(), Result.t(), map(), String.t(), ResultHandler.t()) ::
          Plug.Conn.t()
  def send_result(
        conn,
        %Result{kind: :response, response: response, provider: provider, model: model},
        api_key,
        trace_id,
        %ResultHandler{} = handler
      ) do
    handler.non_stream.(conn, provider, response, api_key, model, trace_id)
  end

  def send_result(
        conn,
        %Result{kind: :stream, stream: stream, token: token, provider: provider, model: model},
        api_key,
        trace_id,
        %ResultHandler{} = handler
      ) do
    handler.stream.(conn, provider, stream, api_key, model, token, trace_id)
  end

  @spec send_error(Plug.Conn.t(), term(), ErrorHandler.t()) :: Plug.Conn.t()
  def send_error(conn, reason, %ErrorHandler{} = handler) do
    case reason do
      {:provider, %Result{provider: provider} = result} ->
        handler.on_provider_error.(result)
        send_provider_error(conn, provider, result, handler)

      {:permission, reason} ->
        handler.send_error.(conn, 403, "permission_error", reason)

      {:not_found, reason} ->
        handler.send_error.(conn, 404, "not_found_error", reason)

      {:guardrail, reason} ->
        message = ErrorResponse.safe_message(reason, "Request blocked by guardrail")
        handler.send_error.(conn, 403, "permission_error", message)

      {:concurrency_limit, _limit} ->
        conn
        |> Plug.Conn.put_resp_header(
          "retry-after",
          Integer.to_string(ConcurrencyLimiter.retry_after_seconds())
        )
        |> handler.send_error.(429, "rate_limit_error", ConcurrencyLimiter.error_message())
    end
  end

  defp send_provider_error(
         conn,
         provider,
         %Result{error: error, status: status} = result,
         %ErrorHandler{} = handler
       ) do
    safe_error = ErrorResponse.safe_message(error, "Provider request failed")
    Logger.error("#{provider.name()} error (#{status}): #{safe_error}")

    handler.send_error.(
      conn,
      status,
      handler.provider_error_type.(status),
      Result.client_error(result)
    )
  end
end
