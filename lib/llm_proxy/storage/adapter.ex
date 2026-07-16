defmodule LLMProxy.Storage.Adapter do
  @moduledoc """
  Behaviour for persistence adapters that back LLMProxy storage operations.
  """

  @callback create_key(String.t(), map()) :: {:ok, term(), String.t()} | {:error, term()}
  @callback find_key(String.t()) :: term() | nil
  @callback list_keys(map()) :: [term()]
  @callback delete_key(term()) :: {:ok, term()} | {:error, term()}
  @callback update_key_usage(term(), map()) :: term()
  @callback update_key_quota(term(), map()) :: {:ok, term()} | {:error, term()}
  @callback update_key_models(term(), list() | nil) :: {:ok, term()} | {:error, term()}
  @callback check_model_access(term(), String.t()) :: :ok | {:error, String.t()}
  @callback record_usage(map()) :: {:ok, term()} | {:error, term()}
  @callback get_usage_in_window(String.t(), integer()) :: map()
  @callback get_message_count_in_window(String.t(), integer()) :: integer()
  @callback get_cache_ratio_in_window(String.t(), integer()) :: {float(), integer()}
  @callback check_quota(term()) :: :ok | {:error, String.t()}
  @callback record_service_usage(map()) :: {:ok, term()} | {:error, term()}
  @callback get_service_usage_in_window(String.t(), String.t(), integer()) :: integer()
  @callback check_service_quota(term(), String.t()) :: :ok | {:error, String.t()}
  @callback get_tokens(String.t(), String.t()) :: [term()]
  @callback list_tokens(map()) :: [term()]
  @callback add_token(String.t(), String.t(), String.t(), map()) ::
              {:ok, term()} | {:error, term()}
  @callback remove_token(term()) :: {:ok, term()} | {:error, term()}
  @callback set_token_enabled(term(), boolean()) :: {:ok, term()} | {:error, term()}
  @callback update_token_proxy(term(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  @callback update_token_oauth(term(), map()) :: {:ok, term()} | {:error, term()}
  @callback seed_tokens_from_env([map()]) :: :ok
  @callback log_message(map()) :: {:ok, term()} | {:error, term()}
  @callback update_message_usage(term(), map()) :: {:ok, term()} | {:error, term()}
  @callback get_messages(map()) :: [term()]
  @callback get_stats(map()) :: map()
  @callback record_trace(map()) :: {:ok, term()} | {:error, term()}
  @callback get_traces(map()) :: [term()]
  @callback get_trace(term()) :: term() | nil
  @callback record_trace_feedback(map()) :: {:ok, term()} | {:error, term()}
  @callback list_trace_feedback(term()) :: [term()]
  @callback get_trace_feedback(integer()) :: [term()]
  @callback find_trace_by_request_id(String.t()) :: term() | nil
  @callback get_daily_stats(map()) :: [term()]
end
