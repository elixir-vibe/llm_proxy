if Code.ensure_loaded?(Incant) do
  defmodule LLMProxy.Admin.Transport do
    @moduledoc false

    @spec redact_sensitive_result(term(), String.t(), module()) :: term()
    def redact_sensitive_result({:ok, payload}, surface_id, admin)
        when is_binary(surface_id) and is_atom(admin) do
      sensitive_columns = sensitive_columns(admin, surface_id)
      {:ok, redact_payload(payload, sensitive_columns)}
    end

    def redact_sensitive_result(result, _surface_id, _admin), do: result

    defp sensitive_columns(admin, surface_id) do
      admin
      |> Incant.Admin.describe()
      |> Map.get(:resources, [])
      |> Enum.find(&(&1.id == surface_id))
      |> case do
        nil -> MapSet.new()
        resource -> sensitive_column_ids(resource)
      end
    end

    defp sensitive_column_ids(resource) do
      resource.table.columns
      |> Enum.filter(&Incant.Sensitive.sensitive?(&1.opts))
      |> Enum.map(& &1.id)
      |> MapSet.new()
    end

    defp redact_payload(%{"rows" => rows} = payload, sensitive_columns) do
      Map.put(payload, "rows", Enum.map(rows, &redact_row(&1, sensitive_columns)))
    end

    defp redact_payload(payload, sensitive_columns),
      do: redact_row(payload, sensitive_columns)

    defp redact_row(%{"cells" => cells} = row, sensitive_columns) do
      Map.put(row, "cells", Enum.map(cells, &redact_cell(&1, sensitive_columns)))
    end

    defp redact_row(row, _sensitive_columns), do: row

    defp redact_cell(%{"column" => column} = cell, sensitive_columns) do
      if MapSet.member?(sensitive_columns, column),
        do: Map.put(cell, "value", Incant.Sensitive.redact(nil)),
        else: cell
    end

    defp redact_cell(cell, _sensitive_columns), do: cell
  end
end
