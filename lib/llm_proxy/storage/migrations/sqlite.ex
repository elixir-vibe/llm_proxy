defmodule LLMProxy.Storage.Migrations.SQLite do
  @moduledoc """
  SQLite migration adapter for installing the shared LLMProxy storage schema.
  """

  @behaviour LLMProxy.Storage.Migrations.Adapter

  alias LLMProxy.Storage.Migrations.Schema

  def up(_opts), do: Schema.up()
  def down(_opts), do: Schema.down()
end
