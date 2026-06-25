defmodule LLMProxy.RPC.AdminServer do
  @moduledoc """
  SafeRPC socket server for the LLMProxy Incant admin surface.
  """

  use SafeRPC.Adapter.Server, service: LLMProxy.Admin
end
