defmodule LLMProxy.Storage.Migrations.QuackDB do
  @moduledoc false

  @behaviour LLMProxy.Storage.Migrations.Adapter

  alias LLMProxy.Storage.Migrations.Schema

  def up(_opts), do: Schema.up()
  def down(_opts), do: Schema.down()
end
