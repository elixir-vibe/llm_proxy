defmodule LLMProxy.Storage.Migrations.Adapter do
  @moduledoc """
  Behaviour for database-specific migration modules used by embedded host applications.
  """

  @callback up(keyword()) :: :ok | any()
  @callback down(keyword()) :: :ok | any()
end
