defmodule LLMProxy.Admin.Query do
  @moduledoc false

  def options(params) do
    table = Map.get(params, :table, Map.get(params, "table", %{}))

    %{
      table: table,
      filters: value(table, :filters, %{}),
      search: value(table, :search)
    }
  end

  def result(page) do
    %Incant.Result{
      rows: page.rows,
      total_count: page.total,
      meta: %{
        page: page.page,
        page_size: page.page_size,
        options: normalize_options(Map.get(page, :options, %{}))
      }
    }
  end

  defp normalize_options(options) do
    Map.new(options, fn {name, values} ->
      {to_string(name), Enum.map(values, &%{label: to_string(&1), value: &1})}
    end)
  end

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, to_string(key), default))
end
