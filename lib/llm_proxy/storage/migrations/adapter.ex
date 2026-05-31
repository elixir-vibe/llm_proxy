defmodule LLMProxy.Storage.Migrations.Adapter do
  @moduledoc false

  @callback up(keyword()) :: :ok | any()
  @callback down(keyword()) :: :ok | any()
end
