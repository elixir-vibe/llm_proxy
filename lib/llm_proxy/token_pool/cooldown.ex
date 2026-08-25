defmodule LLMProxy.TokenPool.Cooldown do
  @moduledoc false

  @account_scope "account"
  @model_scope "model"
  @account_model_key "account"
  @max_model_bytes 512
  @max_duration_ms :timer.hours(24) * 31

  @spec account_scope() :: String.t()
  def account_scope, do: @account_scope

  @spec model_scope() :: String.t()
  def model_scope, do: @model_scope

  @spec account_model_key() :: String.t()
  def account_model_key, do: @account_model_key

  @spec model_key!(String.t()) :: String.t()
  def model_key!(model) when is_binary(model) do
    if valid_model?(model) do
      model
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    else
      raise ArgumentError, "model must be a bounded non-empty string without control characters"
    end
  end

  def model_key!(model) do
    raise ArgumentError, "model must be a bounded non-empty string, got: #{inspect(model)}"
  end

  @spec valid_duration?(term()) :: boolean()
  def valid_duration?(duration_ms),
    do: is_integer(duration_ms) and duration_ms > 0 and duration_ms <= @max_duration_ms

  @spec duration!(term()) :: pos_integer()
  def duration!(duration_ms) do
    if valid_duration?(duration_ms) do
      duration_ms
    else
      raise ArgumentError,
            "token cooldown must be between 1 and #{@max_duration_ms} milliseconds"
    end
  end

  defp valid_model?(model) do
    byte_size(model) in 1..@max_model_bytes and
      String.valid?(model) and
      String.trim(model) == model and
      not Regex.match?(~r/\p{Cc}/u, model)
  end
end
