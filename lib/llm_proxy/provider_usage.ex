defmodule LLMProxy.ProviderUsage do
  @moduledoc """
  Live upstream usage-window state for configured provider accounts.

  Provider credentials stay behind the provider-token codec boundary. Public
  functions return only redacted account labels, quota values, timestamps, and
  safe status text.
  """

  alias LLMProxy.ProviderUsage.{Server, Snapshot, Source}

  @columns [
    :provider,
    :account,
    :window,
    :used_percent,
    :remaining_percent,
    :resets_at,
    :availability,
    :state,
    :last_refresh,
    :last_attempt,
    :error
  ]

  @spec snapshots() :: [Snapshot.t()]
  def snapshots do
    if Process.whereis(Server) do
      Server.snapshots()
    else
      []
    end
  end

  @spec rows() :: %{columns: [atom()], rows: [map()]}
  def rows do
    %{columns: @columns, rows: Enum.flat_map(snapshots(), &snapshot_rows/1)}
  end

  @spec account_count() :: non_neg_integer()
  def account_count, do: length(snapshots())

  @spec available_count() :: non_neg_integer()
  def available_count do
    Enum.count(snapshots(), &(&1.availability in [:available, :limited]))
  end

  @spec attention_count() :: non_neg_integer()
  def attention_count do
    Enum.count(snapshots(), &(&1.state in [:stale, :error] or &1.availability == :unavailable))
  end

  @spec refresh_all() :: {:ok, :started | :already_refreshing} | {:error, :unavailable}
  def refresh_all do
    if Process.whereis(Server), do: Server.refresh_all(), else: {:error, :unavailable}
  end

  @spec refresh_account(pos_integer()) ::
          {:ok, :started | :already_refreshing} | {:error, :unsupported | :unavailable}
  def refresh_account(id) when is_integer(id) and id > 0 do
    if Source.supported_account?(id) do
      if Process.whereis(Server) do
        Server.refresh_account(id)
      else
        {:error, :unavailable}
      end
    else
      {:error, :unsupported}
    end
  end

  def refresh_account(_id), do: {:error, :unsupported}

  defp snapshot_rows(%Snapshot{windows: []} = snapshot), do: [snapshot_row(snapshot, nil)]

  defp snapshot_rows(%Snapshot{} = snapshot) do
    Enum.map(snapshot.windows, &snapshot_row(snapshot, &1))
  end

  defp snapshot_row(snapshot, window) do
    %{
      provider: snapshot.provider_label,
      account: snapshot.account_label,
      window: window && window.label,
      used_percent: window && window.used_percent,
      remaining_percent: window && window.remaining_percent,
      resets_at: window && window.resets_at,
      availability: humanize(snapshot.availability),
      state: humanize(snapshot.state),
      last_refresh: snapshot.refreshed_at,
      last_attempt: snapshot.attempted_at,
      error: snapshot.error
    }
  end

  defp humanize(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
