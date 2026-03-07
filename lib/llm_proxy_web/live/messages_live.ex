defmodule LLMProxyWeb.MessagesLive do
  use Phoenix.LiveView

  import LLMProxyWeb.AdminComponents

  alias LLMProxy.Storage

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page: 0, messages: load_messages(0), page_title: "Messages")}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, current_path: URI.parse(uri).path)}
  end

  @impl true
  def handle_event("prev_page", _, socket) do
    page = max(socket.assigns.page - 1, 0)
    {:noreply, assign(socket, page: page, messages: load_messages(page))}
  end

  def handle_event("next_page", _, socket) do
    page = socket.assigns.page + 1
    messages = load_messages(page)

    if messages == [] do
      {:noreply, socket}
    else
      {:noreply, assign(socket, page: page, messages: messages)}
    end
  end

  defp load_messages(page) do
    Storage.get_messages(%{limit: @per_page, offset: page * @per_page})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current_path={@current_path} />
    <div class="max-w-7xl mx-auto px-4">
      <h1 class="text-2xl font-bold text-gray-900 mb-6">Message Log</h1>

      <div class="bg-white rounded-lg shadow overflow-x-auto">
        <table class="w-full text-sm">
          <thead>
            <tr class="text-left text-gray-500 border-b">
              <th class="px-4 py-3">Time</th>
              <th class="px-4 py-3">Key Name</th>
              <th class="px-4 py-3">Model</th>
              <th class="px-4 py-3">Route</th>
              <th class="px-4 py-3">Message</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={msg <- @messages} class="border-b border-gray-100 hover:bg-gray-50">
              <td class="px-4 py-3 text-gray-500 whitespace-nowrap">{format_time(msg.timestamp)}</td>
              <td class="px-4 py-3 font-medium">{msg.key_name}</td>
              <td class="px-4 py-3 font-mono text-xs">{msg.model}</td>
              <td class="px-4 py-3 text-xs">{msg.route}</td>
              <td class="px-4 py-3 text-xs text-gray-600 max-w-md truncate">{msg.user_message}</td>
            </tr>
          </tbody>
        </table>
        <p :if={@messages == []} class="px-4 py-8 text-center text-gray-400">No messages logged</p>
      </div>

      <div class="flex justify-between items-center mt-4">
        <button
          :if={@page > 0}
          phx-click="prev_page"
          class="px-3 py-1.5 text-sm bg-white border rounded-md hover:bg-gray-50"
        >
          ← Previous
        </button>
        <span class="text-sm text-gray-500">Page {@page + 1}</span>
        <button
          :if={length(@messages) == @per_page}
          phx-click="next_page"
          class="px-3 py-1.5 text-sm bg-white border rounded-md hover:bg-gray-50"
        >
          Next →
        </button>
      </div>
    </div>
    """
  end

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_time(_), do: ""
end
