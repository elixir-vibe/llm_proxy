defmodule LLMProxyWeb.TokensLive do
  use Phoenix.LiveView

  import LLMProxyWeb.AdminComponents

  alias LLMProxy.Storage
  alias LLMProxy.TokenPool.Server, as: TokenPool

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, tokens: Storage.list_tokens(), page_title: "Token Pool")}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, current_path: URI.parse(uri).path)}
  end

  @impl true
  def handle_event("add_token", %{"provider" => provider, "kind" => kind, "token" => token} = params, socket) do
    proxy = params["proxy"]
    opts = if proxy && proxy != "", do: %{proxy: proxy}, else: %{}

    case Storage.add_token(provider, kind, token, opts) do
      {:ok, _} -> {:noreply, assign(socket, tokens: Storage.list_tokens())}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to add token")}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id, "enabled" => enabled}, socket) do
    Storage.set_token_enabled(id, enabled == "true")
    {:noreply, assign(socket, tokens: Storage.list_tokens())}
  end

  def handle_event("delete_token", %{"id" => id}, socket) do
    Storage.remove_token(id)
    {:noreply, assign(socket, tokens: Storage.list_tokens())}
  end

  def handle_event("clear_rate_limits", _, socket) do
    TokenPool.clear_rate_limits()
    {:noreply, put_flash(socket, :info, "Rate limits cleared")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current_path={@current_path} />
    <div class="max-w-7xl mx-auto px-4">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold text-gray-900">Token Pool</h1>
        <button
          phx-click="clear_rate_limits"
          class="px-3 py-1.5 bg-yellow-500 text-white text-sm rounded-md hover:bg-yellow-600"
        >
          Clear Rate Limits
        </button>
      </div>

      <form phx-submit="add_token" class="flex gap-2 mb-6 flex-wrap">
        <select
          name="provider"
          required
          class="px-3 py-2 border border-gray-300 rounded-md text-sm"
        >
          <option value="anthropic">anthropic</option>
          <option value="openai">openai</option>
          <option value="openrouter">openrouter</option>
          <option value="openai-codex">openai-codex</option>
        </select>
        <select name="kind" required class="px-3 py-2 border border-gray-300 rounded-md text-sm">
          <option value="api-key">api-key</option>
          <option value="oauth">oauth</option>
        </select>
        <input
          type="text"
          name="token"
          placeholder="Token value"
          required
          class="flex-1 min-w-[200px] px-3 py-2 border border-gray-300 rounded-md text-sm focus:ring-2 focus:ring-blue-500 focus:outline-none"
        />
        <input
          type="text"
          name="proxy"
          placeholder="Proxy URL (optional)"
          class="px-3 py-2 border border-gray-300 rounded-md text-sm"
        />
        <button
          type="submit"
          class="px-4 py-2 bg-blue-600 text-white text-sm rounded-md hover:bg-blue-700"
        >
          Add
        </button>
      </form>

      <div class="bg-white rounded-lg shadow overflow-x-auto">
        <table class="w-full text-sm">
          <thead>
            <tr class="text-left text-gray-500 border-b">
              <th class="px-4 py-3">Provider</th>
              <th class="px-4 py-3">Kind</th>
              <th class="px-4 py-3">Token</th>
              <th class="px-4 py-3">Label</th>
              <th class="px-4 py-3">Enabled</th>
              <th class="px-4 py-3">Proxy</th>
              <th class="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={token <- @tokens} class="border-b border-gray-100 hover:bg-gray-50">
              <td class="px-4 py-3 font-medium">{token.provider}</td>
              <td class="px-4 py-3">{token.kind}</td>
              <td class="px-4 py-3 font-mono text-xs text-gray-500">{mask_token(token.token)}</td>
              <td class="px-4 py-3 text-xs text-gray-500">{token.label || ""}</td>
              <td class="px-4 py-3">
                <button
                  phx-click="toggle_enabled"
                  phx-value-id={token.id}
                  phx-value-enabled={to_string(!token.enabled)}
                  class={[
                    "px-2 py-0.5 rounded text-xs font-medium",
                    if(token.enabled, do: "bg-green-100 text-green-800", else: "bg-red-100 text-red-800")
                  ]}
                >
                  {if token.enabled, do: "ON", else: "OFF"}
                </button>
              </td>
              <td class="px-4 py-3 text-xs text-gray-500 font-mono">{token.proxy || ""}</td>
              <td class="px-4 py-3 text-right">
                <button
                  phx-click="delete_token"
                  phx-value-id={token.id}
                  data-confirm="Delete this token?"
                  class="text-red-600 hover:text-red-800 text-xs"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
        <p :if={@tokens == []} class="px-4 py-8 text-center text-gray-400">No tokens configured</p>
      </div>
    </div>
    """
  end

  defp mask_token(token) when byte_size(token) > 12 do
    String.slice(token, 0, 6) <> "…" <> String.slice(token, -4, 4)
  end

  defp mask_token(_), do: "***"
end
