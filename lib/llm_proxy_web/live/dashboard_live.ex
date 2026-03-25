defmodule LLMProxyWeb.DashboardLive do
  use Phoenix.LiveView

  import LLMProxyWeb.AdminComponents

  alias LLMProxy.Storage

  @impl true
  def mount(_params, _session, socket) do
    stats = Storage.get_stats()

    {:ok, assign(socket, stats: stats, page_title: "Dashboard")}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, current_path: URI.parse(uri).path)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current_path={@current_path} />
    <div class="max-w-7xl mx-auto px-4">
      <h1 class="text-2xl font-bold text-gray-900 mb-6">Dashboard</h1>

      <div class="grid grid-cols-2 md:grid-cols-5 gap-4 mb-8">
        <.stat_card label="API Keys" value={@stats.total_keys} />
        <.stat_card label="Requests" value={format_number(@stats.total_requests)} />
        <.stat_card label="Total Spend" value={format_usd(@stats.total_spend_usd)} />
        <.stat_card label="Input Tokens" value={format_number(@stats.total_input_tokens)} />
        <.stat_card label="Output Tokens" value={format_number(@stats.total_output_tokens)} />
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div class="bg-white rounded-lg shadow p-6">
          <h2 class="text-lg font-semibold mb-4">Recent Requests</h2>
          <div class="overflow-x-auto">
            <table class="w-full text-sm">
              <thead>
                <tr class="text-left text-gray-500 border-b">
                  <th class="pb-2">Time</th>
                  <th class="pb-2">Model</th>
                  <th class="pb-2">In</th>
                  <th class="pb-2">Out</th>
                  <th class="pb-2">Cost</th>
                  <th class="pb-2">Latency</th>
                  <th class="pb-2">TTFT</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={r <- Enum.take(@stats.recent_usage, 15)} class="border-b border-gray-100">
                  <td class="py-1.5 text-gray-500">{format_time(r.timestamp)}</td>
                  <td class="py-1.5 font-mono text-xs">{r.model}</td>
                  <td class="py-1.5 text-right">{format_number(r.input_tokens)}</td>
                  <td class="py-1.5 text-right">{format_number(r.output_tokens)}</td>
                  <td class="py-1.5 text-right text-gray-600">{format_usd(r.cost_usd)}</td>
                  <td class="py-1.5 text-right text-gray-500">{format_ms(r.duration_ms)}</td>
                  <td class="py-1.5 text-right text-gray-500">{format_ms(r.ttft_ms)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="bg-white rounded-lg shadow p-6">
          <h2 class="text-lg font-semibold mb-4">Service Usage</h2>
          <div :for={s <- @stats.service_stats} class="flex justify-between py-2 border-b border-gray-100">
            <span class="font-medium">{s.service}</span>
            <span class="text-gray-600">{format_number(s.count)} requests</span>
          </div>
          <p :if={@stats.service_stats == []} class="text-gray-400">No service usage yet</p>
        </div>
      </div>
    </div>
    """
  end

  defp stat_card(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow p-4">
      <dt class="text-sm text-gray-500">{@label}</dt>
      <dd class="text-2xl font-semibold text-gray-900 mt-1">{@value}</dd>
    </div>
    """
  end

  defp format_number(n) when is_integer(n) and n >= 1_000_000, do: "#{div(n, 1_000_000)}M"
  defp format_number(n) when is_integer(n) and n >= 1_000, do: "#{div(n, 1_000)}K"
  defp format_number(n), do: to_string(n)

  defp format_ms(nil), do: "—"
  defp format_ms(ms) when ms >= 1000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_ms(ms), do: "#{ms}ms"

  defp format_usd(nil), do: "—"
  defp format_usd(n) when is_float(n) and n >= 1.0, do: "$#{:erlang.float_to_binary(n, decimals: 2)}"
  defp format_usd(n) when is_float(n), do: "$#{:erlang.float_to_binary(n, decimals: 4)}"
  defp format_usd(n) when is_number(n), do: format_usd(n / 1)

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(_), do: ""
end
