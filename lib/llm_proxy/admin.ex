if Code.ensure_loaded?(Incant) do
  defmodule LLMProxy.Admin do
    @moduledoc """
    Service-owned Incant admin interface for LLMProxy.

    This module is the stable admin surface that can be described locally with
    `Incant.Admin.describe/1` and later exposed over SafeRPC.
    """

    alias LLMProxy.Admin.Transport

    use Incant.Admin,
      service: :llm_proxy,
      version: "1",
      title: "LLM Proxy",
      naming: [
        terms: %{
          openai: "OpenAI",
          openai_codex: "OpenAI Codex",
          openrouter: "OpenRouter",
          req_llm: "ReqLLM"
        }
      ],
      repo: LLMProxy.Storage.Repo,
      policy: LLMProxy.Admin.Policy,
      rpc: true

    resource(LLMProxy.Admin.Resources.ApiKey)
    expose(LLMProxy.Schemas.ProviderToken)
    expose(LLMProxy.Schemas.Trace, readonly: true)
    expose(LLMProxy.Schemas.MessageLog, as: :message, readonly: true)

    dashboard(LLMProxy.Admin.Dashboards.Operations)

    @impl Incant.Service
    def index(surface_id, params, context) when is_binary(surface_id) do
      super(surface_id, params, context)
      |> Transport.redact_sensitive_result(surface_id, __MODULE__)
    end

    @impl Incant.Service
    def read(surface_id, id, context) when is_binary(surface_id) do
      super(surface_id, id, context)
      |> Transport.redact_sensitive_result(surface_id, __MODULE__)
    end
  end
end
