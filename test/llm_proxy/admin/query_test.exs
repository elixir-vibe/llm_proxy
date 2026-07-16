defmodule LLMProxy.Admin.QueryTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Admin.Query

  test "normalizes Incant table state for storage" do
    table = %{
      page: "2",
      page_size: "10",
      sort: "-timestamp",
      search: "codex",
      filters: %{"provider" => "openai-codex"}
    }

    assert Query.options(%{table: table}) == %{
             table: table,
             search: "codex",
             filters: %{"provider" => "openai-codex"}
           }
  end

  test "returns existing Incant result and option representations" do
    result =
      Query.result(%{
        rows: [%{id: 1}],
        page: 2,
        page_size: 10,
        total: 31,
        total_pages: 4,
        options: %{"model" => ["gpt-5", "gpt-5-mini"]}
      })

    assert %Incant.Result{rows: [%{id: 1}], total_count: 31} = result
    assert result.meta.page == 2
    assert result.meta.page_size == 10

    assert result.meta.options["model"] == [
             %{label: "gpt-5", value: "gpt-5"},
             %{label: "gpt-5-mini", value: "gpt-5-mini"}
           ]
  end
end
