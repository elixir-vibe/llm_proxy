defmodule LLMProxy.Storage.Migrations.Postgres do
  @moduledoc """
  PostgreSQL migration adapter for installing the shared LLMProxy storage schema.
  """

  @behaviour LLMProxy.Storage.Migrations.Adapter

  alias LLMProxy.Storage.Migrations.Schema

  def up(_opts), do: Schema.up()
  def down(_opts), do: Schema.down()
end
