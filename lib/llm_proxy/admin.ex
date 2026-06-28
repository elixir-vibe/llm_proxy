defmodule LLMProxy.Admin do
  @moduledoc """
  Service-owned Incant admin interface for LLMProxy.

  This module is the stable admin surface that can be described locally with
  `Incant.Admin.describe/1` and later exposed over SafeRPC.
  """

  use Incant.Admin,
    service: :llm_proxy,
    version: "1",
    repo: LLMProxy.Storage.Repo,
    policy: LLMProxy.Admin.Policy,
    rpc: true

  expose(LLMProxy.Schemas.ApiKey)
  expose(LLMProxy.Schemas.ProviderToken)
  expose(LLMProxy.Schemas.Trace, readonly: true)
  expose(LLMProxy.Schemas.MessageLog, as: :message, readonly: true)

  dashboard(LLMProxy.Admin.Dashboards.Operations)
end
