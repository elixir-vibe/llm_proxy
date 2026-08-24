defmodule LLMProxy.ProviderUsage.Loader do
  @moduledoc false

  alias LLMProxy.Provider.TokenCodec
  alias LLMProxy.ProviderUsage.{Result, Snapshot, Source}

  @spec refresh(:all | {:account, integer()}) :: [Snapshot.t()]
  def refresh(scope) do
    Source.accounts()
    |> select(scope)
    |> Enum.map(&refresh_source/1)
  end

  defp select(sources, :all), do: sources
  defp select(sources, {:account, id}), do: Enum.filter(sources, &(&1.token_id == id))

  defp refresh_source(%Source{} = source) do
    do_refresh_source(source)
  catch
    _kind, _reason -> error_snapshot(source, now(), :refresh_failed)
  end

  defp do_refresh_source(%Source{stored_token: %{enabled: false}} = source) do
    snapshot(source,
      availability: :unavailable,
      state: :disabled,
      error: "Provider token is disabled"
    )
  end

  defp do_refresh_source(%Source{config_error: error} = source) when is_binary(error) do
    snapshot(source,
      availability: :unknown,
      state: :error,
      attempted_at: now(),
      error: error
    )
  end

  defp do_refresh_source(%Source{} = source) do
    attempted_at = now()

    with {:ok, credential} <- TokenCodec.credential(source.stored_token),
         {:ok, %Result{} = result} <- source.adapter.fetch(credential, source) do
      snapshot(source,
        availability: result.availability,
        state: :fresh,
        plan: result.plan,
        reset_credits_available: result.reset_credits_available,
        reset_credit_expires_at: result.reset_credit_expires_at,
        windows: result.windows,
        refreshed_at: attempted_at,
        attempted_at: attempted_at
      )
    else
      {:error, {:provider_token_codec, _reason}} ->
        error_snapshot(source, attempted_at, :credential_unavailable)

      {:error, reason} ->
        error_snapshot(source, attempted_at, reason)
    end
  end

  defp error_snapshot(source, attempted_at, reason) do
    snapshot(source,
      availability: :unknown,
      state: :error,
      attempted_at: attempted_at,
      error: safe_error(reason)
    )
  end

  defp snapshot(source, attrs) do
    struct!(Snapshot, %{
      token_id: source.token_id,
      provider_label: source.provider_label,
      account_label: source.account_label,
      plan: Keyword.get(attrs, :plan),
      reset_credits_available: Keyword.get(attrs, :reset_credits_available),
      reset_credit_expires_at: Keyword.get(attrs, :reset_credit_expires_at),
      availability: Keyword.fetch!(attrs, :availability),
      state: Keyword.fetch!(attrs, :state),
      windows: Keyword.get(attrs, :windows, []),
      refreshed_at: Keyword.get(attrs, :refreshed_at),
      attempted_at: Keyword.get(attrs, :attempted_at),
      error: Keyword.get(attrs, :error)
    })
  end

  defp safe_error(:unsupported), do: "Provider does not report usage for this account"
  defp safe_error(:authentication_failed), do: "Provider authentication failed"
  defp safe_error(:credential_expired), do: "Provider credential expired"
  defp safe_error(:credential_unavailable), do: "Provider credential is unavailable"
  defp safe_error(:token_refresh_failed), do: "Provider credential refresh failed"
  defp safe_error(:rate_limited), do: "Provider usage API is rate limited"
  defp safe_error(:timeout), do: "Provider usage API timed out"
  defp safe_error(:unavailable), do: "Provider usage API is unavailable"
  defp safe_error(:not_found), do: "Provider usage API is unsupported"
  defp safe_error(:invalid_response), do: "Provider returned invalid usage data"
  defp safe_error(:response_too_large), do: "Provider returned invalid usage data"
  defp safe_error({:invalid_response, _reason}), do: "Provider returned invalid usage data"
  defp safe_error(_reason), do: "Provider usage refresh failed"

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
