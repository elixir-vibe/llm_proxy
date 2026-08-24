defmodule LLMProxy.Provider.TokenCodec.Migration do
  @moduledoc """
  Explicit migration tools for stored provider credentials.

  Encryption and plaintext rollback run in one database transaction. Status and
  verification return counts only. They never return credential values.
  """

  import Ecto.Query

  alias LLMProxy.Provider.TokenCodec
  alias LLMProxy.Schemas.ProviderToken
  alias LLMProxy.Storage.Repo

  @fields [:token, :refresh_token]

  @type counts :: %{
          rows: non_neg_integer(),
          encrypted_fields: non_neg_integer(),
          plaintext_fields: non_neg_integer()
        }

  @spec status() :: {:ok, counts()} | {:error, term()}
  def status do
    with {:ok, _module, _options} <- TokenCodec.configured() do
      rows = Repo.all(from(t in ProviderToken, order_by: [asc: t.id]))
      {:ok, count(rows)}
    end
  end

  @spec verify() :: {:ok, counts()} | {:error, term()}
  def verify do
    rows = Repo.all(from(t in ProviderToken, order_by: [asc: t.id]))

    with :ok <- verify_rows(rows) do
      {:ok, count(rows)}
    end
  end

  @spec encrypt_all() :: {:ok, map()} | {:error, term()}
  def encrypt_all, do: migrate(:encrypt)

  @spec decrypt_all() :: {:ok, map()} | {:error, term()}
  def decrypt_all, do: migrate(:decrypt)

  @spec rotate_all() :: {:ok, map()} | {:error, term()}
  def rotate_all, do: migrate(:rotate)

  defp migrate(direction) do
    Repo.transaction(fn ->
      ProviderToken
      |> order_by([t], asc: t.id)
      |> Repo.all()
      |> Enum.reduce(
        %{rows: 0, changed_rows: 0, changed_fields: 0},
        &migrate_and_count(&1, &2, direction)
      )
    end)
  end

  defp migrate_and_count(row, counts, direction) do
    case migrate_row(row, direction) do
      {:ok, changed_fields} -> update_counts(counts, changed_fields)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_counts(counts, changed_fields) do
    %{
      rows: counts.rows + 1,
      changed_rows: counts.changed_rows + if(changed_fields == 0, do: 0, else: 1),
      changed_fields: counts.changed_fields + changed_fields
    }
  end

  defp migrate_row(row, direction) do
    with {:ok, attrs, changed_fields} <- migrated_attrs(row, direction),
         {:ok, _stored} <- maybe_update(row, attrs) do
      {:ok, changed_fields}
    end
  end

  defp migrated_attrs(row, direction) do
    Enum.reduce_while(@fields, {:ok, %{}, 0}, fn field, {:ok, attrs, changed} ->
      value = Map.get(row, field)

      case migrate_value(value, field, direction) do
        {:ok, ^value} -> {:cont, {:ok, attrs, changed}}
        {:ok, migrated} -> {:cont, {:ok, Map.put(attrs, field, migrated), changed + 1}}
        {:error, reason} -> {:halt, {:error, {:provider_token_codec, reason}}}
      end
    end)
  end

  defp migrate_value(nil, _field, _direction), do: {:ok, nil}
  defp migrate_value("", _field, _direction), do: {:ok, ""}

  defp migrate_value(value, field, :encrypt) do
    if TokenCodec.encoded?(value) do
      {:ok, value}
    else
      TokenCodec.encode(value, field)
    end
  end

  defp migrate_value(value, field, :decrypt) do
    if TokenCodec.encoded?(value) do
      TokenCodec.decode(value, field)
    else
      {:ok, value}
    end
  end

  defp migrate_value(value, field, :rotate) do
    with {:ok, plaintext} <- TokenCodec.decode(value, field) do
      TokenCodec.encode(plaintext, field)
    end
  end

  defp maybe_update(row, attrs) when map_size(attrs) == 0, do: {:ok, row}
  defp maybe_update(row, attrs), do: row |> Ecto.Changeset.change(attrs) |> Repo.update()

  defp verify_rows(rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case verify_row(row) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp verify_row(row) do
    Enum.reduce_while(@fields, :ok, fn field, :ok ->
      case TokenCodec.decode(Map.get(row, field), field) do
        {:ok, _value} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:provider_token_codec, reason}}}
      end
    end)
  end

  defp count(rows) do
    Enum.reduce(rows, %{rows: length(rows), encrypted_fields: 0, plaintext_fields: 0}, fn
      row, counts ->
        Enum.reduce(@fields, counts, &count_field(Map.get(row, &1), &2))
    end)
  end

  defp count_field(nil, counts), do: counts
  defp count_field("", counts), do: counts

  defp count_field(value, counts) do
    key = if TokenCodec.encoded?(value), do: :encrypted_fields, else: :plaintext_fields
    Map.update!(counts, key, &(&1 + 1))
  end
end
