defmodule LLMProxy.ProviderUsage do
  @moduledoc """
  Live upstream usage-window state for configured provider accounts.

  Provider credentials stay behind the provider-token codec boundary. Public
  functions return only redacted account labels, quota values, timestamps, and
  safe status text.
  """

  alias LLMProxy.ProviderUsage.{Server, Snapshot, Source, Window}

  @columns [
    :account,
    :provider,
    :plan,
    :reset_credits_available,
    :reset_credit_expires_in,
    :reset_credit_expires_at,
    :window,
    :used_percent,
    :remaining_percent,
    :remaining_ratio,
    :used_ratio,
    :resets_in,
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
    rows(snapshots())
  end

  @doc false
  @spec rows([Snapshot.t()], DateTime.t()) :: %{columns: [atom()], rows: [map()]}
  def rows(snapshots, now \\ DateTime.utc_now()) do
    rows =
      snapshots
      |> Enum.flat_map(&snapshot_rows(&1, now))
      |> Enum.sort_by(&row_sort_key/1)

    %{columns: @columns, rows: rows}
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

  @spec exhausted_count() :: non_neg_integer()
  def exhausted_count do
    Enum.count(snapshots(), &(&1.state == :fresh and &1.availability == :unavailable))
  end

  @spec token_available?(integer(), DateTime.t()) :: boolean()
  def token_available?(token_id, at \\ DateTime.utc_now()) when is_integer(token_id) do
    snapshots()
    |> Enum.find(&(&1.token_id == token_id))
    |> available_snapshot?(at)
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

  defp snapshot_rows(%Snapshot{windows: []} = snapshot, now),
    do: [snapshot_row(snapshot, nil, now)]

  defp snapshot_rows(%Snapshot{} = snapshot, now) do
    Enum.map(snapshot.windows, &snapshot_row(snapshot, &1, now))
  end

  defp snapshot_row(snapshot, window, now) do
    %{
      account: snapshot.account_label,
      provider: snapshot.provider_label,
      plan: snapshot.plan,
      reset_credits_available: snapshot.reset_credits_available,
      reset_credit_expires_in: reset_distance(snapshot.reset_credit_expires_at, now),
      reset_credit_expires_at: snapshot.reset_credit_expires_at,
      window: window && window.label,
      used_percent: window && window.used_percent,
      remaining_percent: window && window.remaining_percent,
      remaining_ratio: ratio(window && window.remaining_percent),
      used_ratio: ratio(window && window.used_percent),
      resets_in: reset_distance(window && window.resets_at, now),
      resets_at: window && window.resets_at,
      availability: humanize(snapshot.availability),
      state: humanize(snapshot.state),
      last_refresh: snapshot.refreshed_at,
      last_attempt: snapshot.attempted_at,
      error: snapshot.error
    }
  end

  defp row_sort_key(row) do
    attention_rank = if row.availability == "Unavailable" or row.state != "Fresh", do: 0, else: 1
    remaining = if is_number(row.remaining_ratio), do: row.remaining_ratio, else: 2

    {attention_rank, remaining, row.provider, row.account, row.window || ""}
  end

  defp ratio(nil), do: nil
  defp ratio(percent) when is_number(percent), do: percent / 100

  defp reset_distance(nil, _now), do: nil

  defp reset_distance(%DateTime{} = resets_at, %DateTime{} = now) do
    seconds = DateTime.diff(resets_at, now, :second)
    days = div(seconds, 86_400)
    hours = seconds |> rem(86_400) |> div(3_600)
    minutes = seconds |> rem(3_600) |> div(60)

    cond do
      seconds <= 0 -> "now"
      seconds < 60 -> "<1m"
      days > 0 -> "#{days}d #{hours}h"
      hours > 0 -> "#{hours}h #{minutes}m"
      true -> "#{minutes}m"
    end
  end

  defp humanize(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  @doc false
  def available_snapshot?(snapshot, at \\ DateTime.utc_now())

  def available_snapshot?(nil, _at), do: true

  def available_snapshot?(%Snapshot{state: state}, _at)
      when state in [:disabled, :stale, :error], do: true

  def available_snapshot?(%Snapshot{availability: availability}, _at)
      when availability in [:available, :limited],
      do: true

  def available_snapshot?(%Snapshot{availability: :unavailable, windows: windows}, at)
      when is_list(windows) do
    case exhausted_window_resets(windows) do
      {:ok, []} ->
        false

      {:ok, resets} ->
        latest_reset = Enum.max_by(resets, &DateTime.to_unix(&1, :microsecond))
        DateTime.compare(at, latest_reset) != :lt

      :unknown ->
        false
    end
  end

  def available_snapshot?(_snapshot, _at), do: false

  defp exhausted_window_resets(windows) do
    Enum.reduce_while(windows, {:ok, []}, fn
      %Window{used_percent: used_percent, resets_at: %DateTime{} = resets_at}, {:ok, resets}
      when is_number(used_percent) and used_percent >= 100 ->
        {:cont, {:ok, [resets_at | resets]}}

      %Window{used_percent: used_percent, resets_at: nil}, _acc
      when is_number(used_percent) and used_percent >= 100 ->
        {:halt, :unknown}

      %Window{}, acc ->
        {:cont, acc}

      _malformed_window, _acc ->
        {:halt, :unknown}
    end)
  end
end
