defmodule LLMProxyWeb.TracesLive do
  use Phoenix.LiveView

  import LLMProxyWeb.AdminComponents

  alias LLMProxy.Storage

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Traces", trace_detail: nil)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    per_page = 25

    opts =
      %{per_page: per_page}
      |> maybe_put(:key_id, params["key_id"])
      |> maybe_put(:model, params["model"])
      |> maybe_put(:session_id, params["session_id"])
      |> maybe_put(:search, params["search"])
      |> maybe_put_int(:offset, params["offset"])

    traces = Storage.get_traces(opts)
    has_more = length(traces) > per_page
    traces = Enum.take(traces, per_page)
    offset = String.to_integer(params["offset"] || "0")

    {:noreply,
     assign(socket,
       traces: traces,
       has_more: has_more,
       offset: offset,
       per_page: per_page,
       search: params["search"] || "",
       current_path: URI.parse(uri).path
     )}
  end

  @impl true
  def handle_event("view_trace", %{"id" => id}, socket) do
    trace = Storage.get_trace(String.to_integer(id))
    {:noreply, assign(socket, trace_detail: trace)}
  end

  def handle_event("close_trace", _, socket) do
    {:noreply, assign(socket, trace_detail: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current_path={@current_path} />
    <div class="max-w-7xl mx-auto px-4">
      <h1 class="text-2xl font-bold text-gray-900 mb-6">Traces</h1>

      <form method="get" class="mb-4 flex gap-2">
        <input
          type="text"
          name="search"
          value={@search}
          placeholder="Search by model or key name..."
          class="px-3 py-2 border border-gray-300 rounded-md text-sm flex-1 focus:ring-2 focus:ring-blue-500 focus:outline-none"
        />
        <button type="submit" class="px-4 py-2 bg-blue-600 text-white text-sm rounded-md hover:bg-blue-700">
          Search
        </button>
      </form>

      <%= if @trace_detail do %>
        <div class="bg-white rounded-lg shadow p-6 mb-6">
          <div class="flex justify-between items-start mb-4">
            <h2 class="text-lg font-semibold">Trace #{@trace_detail.id}</h2>
            <button phx-click="close_trace" class="text-gray-400 hover:text-gray-600">✕</button>
          </div>
          <div class="grid grid-cols-2 gap-4 mb-4 text-sm">
            <div><span class="text-gray-500">Model:</span> {@trace_detail.model}</div>
            <div><span class="text-gray-500">Provider:</span> {@trace_detail.provider || "—"}</div>
            <div><span class="text-gray-500">Duration:</span> {format_ms(@trace_detail.duration_ms)}</div>
            <div><span class="text-gray-500">TTFT:</span> {format_ms(@trace_detail.ttft_ms)}</div>
            <div><span class="text-gray-500">Cost:</span> {format_usd(@trace_detail.cost_usd)}</div>
            <div><span class="text-gray-500">Session:</span> {@trace_detail.session_id || "—"}</div>
          </div>
          <div class="space-y-4">
            <div>
              <h3 class="text-sm font-medium text-gray-700 mb-1">Request</h3>
              <pre class="bg-gray-50 rounded p-3 text-xs overflow-x-auto max-h-96">{format_json(@trace_detail.request_body)}</pre>
            </div>
            <div>
              <h3 class="text-sm font-medium text-gray-700 mb-1">Response</h3>
              <pre class="bg-gray-50 rounded p-3 text-xs overflow-x-auto max-h-96">{format_json(@trace_detail.response_body)}</pre>
            </div>
          </div>
        </div>
      <% end %>

      <div class="bg-white rounded-lg shadow overflow-x-auto">
        <table class="w-full text-sm">
          <thead>
            <tr class="text-left border-b text-gray-500">
              <th class="px-4 py-3">Time</th>
              <th class="px-4 py-3">Model</th>
              <th class="px-4 py-3">Provider</th>
              <th class="px-4 py-3 text-right">In</th>
              <th class="px-4 py-3 text-right">Out</th>
              <th class="px-4 py-3 text-right">Cost</th>
              <th class="px-4 py-3 text-right">Latency</th>
              <th class="px-4 py-3">Session</th>
              <th class="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={t <- @traces} class="border-b border-gray-100 hover:bg-gray-50">
              <td class="px-4 py-2 text-gray-500 text-xs">{format_time(t.timestamp)}</td>
              <td class="px-4 py-2 font-mono text-xs">{t.model}</td>
              <td class="px-4 py-2 text-xs">{t.provider || "—"}</td>
              <td class="px-4 py-2 text-right font-mono text-xs">{format_number(t.input_tokens)}</td>
              <td class="px-4 py-2 text-right font-mono text-xs">{format_number(t.output_tokens)}</td>
              <td class="px-4 py-2 text-right text-xs">{format_usd(t.cost_usd)}</td>
              <td class="px-4 py-2 text-right text-xs">{format_ms(t.duration_ms)}</td>
              <td class="px-4 py-2 text-xs text-gray-500 truncate max-w-[100px]">{t.session_id || "—"}</td>
              <td class="px-4 py-2 text-right">
                <button
                  phx-click="view_trace"
                  phx-value-id={t.id}
                  class="text-blue-600 hover:text-blue-800 text-xs"
                >
                  View
                </button>
              </td>
            </tr>
          </tbody>
        </table>
        <p :if={@traces == []} class="px-4 py-8 text-center text-gray-400">
          No traces. Enable tracing on an API key to start recording.
        </p>
      </div>

      <div :if={@offset > 0 || @has_more} class="flex justify-between mt-4">
        <.link
          :if={@offset > 0}
          patch={"?offset=#{max(@offset - @per_page, 0)}"}
          class="text-sm text-blue-600 hover:text-blue-800"
        >
          ← Previous
        </.link>
        <span :if={@offset <= 0} />
        <.link
          :if={@has_more}
          patch={"?offset=#{@offset + @per_page}"}
          class="text-sm text-blue-600 hover:text-blue-800"
        >
          Next →
        </.link>
      </div>
    </div>
    """
  end

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%m-%d %H:%M:%S")
  defp format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%m-%d %H:%M:%S")
  defp format_time(_), do: ""

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

  defp format_json(nil), do: "—"

  defp format_json(json_str) when is_binary(json_str) do
    case Jason.decode(json_str) do
      {:ok, parsed} -> Jason.encode!(parsed, pretty: true)
      {:error, _} -> json_str
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_int(map, _key, nil), do: map
  defp maybe_put_int(map, _key, ""), do: map

  defp maybe_put_int(map, key, value) do
    case Integer.parse(value) do
      {int, _} -> Map.put(map, key, int)
      :error -> map
    end
  end
end
