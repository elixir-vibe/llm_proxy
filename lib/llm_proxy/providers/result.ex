defmodule LLMProxy.Providers.Result do
  @moduledoc """
  Provider execution result tagged by response kind.

  Providers return this struct from native and compatibility calls so routing,
  fallback, HTTP route rendering, and token accounting can branch on an explicit
  `:kind` instead of inferring meaning from nullable fields.
  """

  @type kind :: :response | :stream | :error
  @type token :: map() | nil

  @enforce_keys [:kind]
  defstruct [
    :kind,
    :response,
    :stream,
    :error,
    :status,
    :token,
    :retry_after_ms,
    :provider_body,
    :provider,
    :provider_name,
    :model
  ]

  @type t :: %__MODULE__{
          kind: kind(),
          response: map() | nil,
          stream: Enumerable.t() | nil,
          error: String.t() | nil,
          status: pos_integer() | nil,
          token: token(),
          retry_after_ms: non_neg_integer() | nil,
          provider_body: term() | nil,
          provider: module() | nil,
          provider_name: String.t() | nil,
          model: String.t() | nil
        }

  @spec response(map(), token()) :: t()
  def response(body, token) when is_map(body),
    do: %__MODULE__{kind: :response, response: body, token: token}

  @spec stream(Enumerable.t(), token()) :: t()
  def stream(stream, token), do: %__MODULE__{kind: :stream, stream: stream, token: token}

  @spec unavailable_tokens(term()) :: {:error, t()}
  def unavailable_tokens(reason), do: {:error, error("No available tokens: #{reason}", 503, nil)}

  @spec error(String.t(), pos_integer(), token(), keyword()) :: t()
  def error(error, status, token, opts \\ [])
      when is_binary(error) and is_integer(status) and status > 0 do
    %__MODULE__{
      kind: :error,
      error: error,
      status: status,
      token: token,
      retry_after_ms: opts[:retry_after_ms],
      provider_body: opts[:provider_body]
    }
  end

  @spec stream_failure(module(), String.t(), token(), term()) :: t()
  def stream_failure(provider, model, token, reason)
      when is_atom(provider) and is_binary(model) do
    result =
      if Code.ensure_loaded?(provider) and function_exported?(provider, :stream_error, 2) do
        provider.stream_error(reason, token)
      else
        error("Upstream provider stream failed", 502, token)
      end

    %{result | provider: provider, provider_name: provider_name(provider), model: model}
  end

  @spec client_error(t()) :: map()
  def client_error(%__MODULE__{provider_body: %{"error" => error}} = result),
    do: provider_client_error(error, result)

  def client_error(%__MODULE__{provider_body: %{error: error}} = result),
    do: provider_client_error(error, result)

  def client_error(%__MODULE__{provider_body: error} = result) when is_map(error),
    do: provider_client_error(error, result)

  def client_error(%__MODULE__{error: message, status: status}) do
    %{
      "message" => message || "Upstream provider stream failed",
      "type" => error_type(status),
      "code" => error_type(status),
      "status" => status || 502
    }
  end

  @spec with_attempt({:ok, t()} | {:error, t()}, LLMProxy.Providers.Attempt.t()) ::
          {:ok, t()} | {:error, t()}
  def with_attempt({state, %__MODULE__{} = result}, %LLMProxy.Providers.Attempt{} = attempt)
      when state in [:ok, :error] do
    {state,
     %{
       result
       | provider: attempt.provider,
         provider_name: attempt.provider_name || attempt.provider.name(),
         model: attempt.model
     }}
  end

  @spec with_attempt({:ok, t()} | {:error, t()}, module(), String.t()) ::
          {:ok, t()} | {:error, t()}
  def with_attempt({state, %__MODULE__{} = result}, provider, model)
      when state in [:ok, :error] do
    {state, %{result | provider: provider, provider_name: provider_name(provider), model: model}}
  end

  defp provider_client_error(error, %__MODULE__{} = result) when is_map(error) do
    status = result.status || 502
    fallback_code = error_type(status)
    code = normalize_error_code(error_field(error, "code", :code), fallback_code)
    type = normalize_error_code(error_field(error, "type", :type), code)
    message = normalize_error_message(error_field(error, "message", :message), result.error)

    %{
      "message" => message,
      "type" => type,
      "code" => code,
      "status" => status
    }
    |> maybe_put_param(error_field(error, "param", :param))
  end

  defp provider_client_error(message, %__MODULE__{} = result) when is_binary(message),
    do: client_error(%{result | error: message, provider_body: nil})

  defp provider_client_error(_error, %__MODULE__{} = result),
    do: client_error(%{result | provider_body: nil})

  defp error_field(error, string_key, atom_key),
    do: Map.get(error, string_key) || Map.get(error, atom_key)

  defp normalize_error_code(code, _fallback) when is_binary(code) and code != "", do: code
  defp normalize_error_code(_code, fallback), do: fallback

  defp normalize_error_message(message, _fallback) when is_binary(message) and message != "",
    do: message

  defp normalize_error_message(_message, fallback) when is_binary(fallback) and fallback != "",
    do: fallback

  defp normalize_error_message(_message, _fallback), do: "Upstream provider stream failed"

  defp maybe_put_param(error, param) when is_binary(param), do: Map.put(error, "param", param)
  defp maybe_put_param(error, _param), do: error

  defp provider_name(provider) do
    if function_exported?(provider, :name, 0),
      do: provider.name(),
      else: Atom.to_string(provider)
  end

  defp error_type(401), do: "authentication_error"
  defp error_type(403), do: "permission_error"
  defp error_type(429), do: "rate_limit_error"
  defp error_type(status) when is_integer(status) and status >= 500, do: "upstream_error"
  defp error_type(_status), do: "api_error"
end
