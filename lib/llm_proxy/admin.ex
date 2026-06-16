defmodule LLMProxy.Admin do
  @moduledoc """
  Service-owned Incant admin interface for LLMProxy.

  This module is the stable admin surface that can be described locally with
  `Incant.Admin.describe/1` and later exposed over SafeRPC.
  """

  use Incant.Admin, service: :llm_proxy, version: "1"

  resource(LLMProxy.Admin.Resources.ApiKey)
  resource(LLMProxy.Admin.Resources.ProviderToken)
  resource(LLMProxy.Admin.Resources.Trace)
  resource(LLMProxy.Admin.Resources.Message)

  dashboard(LLMProxy.Admin.Dashboards.Operations)
end
