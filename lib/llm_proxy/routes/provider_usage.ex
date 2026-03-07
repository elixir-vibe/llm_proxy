defmodule LLMProxy.Routes.ProviderUsage do
  @moduledoc false
  use Plug.Router

  alias LLMProxy.Plugs.MasterKey
  alias LLMProxy.Storage

  @codex_usage_url "https://chatgpt.com/backend-api/wham/usage"
  @claude_usage_url "https://api.anthropic.com/api/oauth/usage"
  @claude_beta_header "oauth-2025-04-20"
  @jwt_claim_path "https://api.openai.com/auth"

  plug MasterKey
  plug :match
  plug :dispatch

  get "/usage/codex" do
    case Storage.get_tokens("openai-codex", "oauth") do
      [] ->
        send_json(conn, 401, %{error: "OpenAI Codex token not configured"})

      tokens ->
        results =
          tokens
          |> Task.async_stream(&fetch_codex_usage/1, timeout: 30_000)
          |> Enum.map(fn {:ok, result} -> result end)

        send_json(conn, 200, unwrap_single(results))
    end
  end

  get "/usage/claude" do
    case Storage.get_tokens("anthropic", "oauth") do
      [] ->
        send_json(conn, 401, %{error: "Anthropic OAuth token not configured"})

      tokens ->
        results =
          tokens
          |> Task.async_stream(&fetch_claude_usage/1, timeout: 30_000)
          |> Enum.map(fn {:ok, result} -> result end)

        send_json(conn, 200, unwrap_single(results))
    end
  end

  match _ do
    send_json(conn, 404, %{error: "Not found"})
  end

  defp fetch_codex_usage(token) do
    account_id = extract_account_id(token.token)

    headers = [
      {"authorization", "Bearer #{token.token}"},
      {"chatgpt-account-id", account_id},
      {"accept", "application/json"}
    ]

    opts = if token.proxy, do: [connect_options: [proxy: token.proxy]], else: []

    req =
      Req.new([url: @codex_usage_url, headers: headers] ++ opts)
      |> OpentelemetryReq.attach()

    Req.get!(req).body
  end

  defp fetch_claude_usage(token) do
    headers = [
      {"authorization", "Bearer #{token.token}"},
      {"accept", "application/json"},
      {"anthropic-beta", @claude_beta_header}
    ]

    opts = if token.proxy, do: [connect_options: [proxy: token.proxy]], else: []

    req =
      Req.new([url: @claude_usage_url, headers: headers] ++ opts)
      |> OpentelemetryReq.attach()

    Req.get!(req).body
  end

  defp extract_account_id(token) do
    with [_, payload, _] <- String.split(token, "."),
         {:ok, decoded} <- Base.decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(decoded),
         %{"chatgpt_account_id" => account_id} <- claims[@jwt_claim_path] do
      account_id
    else
      _ -> raise "Failed to extract accountId from OpenAI Codex token"
    end
  end

  defp unwrap_single([single]), do: single
  defp unwrap_single(results), do: results

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
