defmodule LLMProxy.Web.MessagesLive do
  use Phoenix.LiveView

  import LLMProxy.Web.AdminComponents

  alias LLMProxy.Storage

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Messages")}
  end

  @impl true
  def handle_params(params, uri, socket) do
    page = parse_page(params["page"])
    sort = params["sort"] || "timestamp"
    dir = params["dir"] || "desc"
    search = params["q"] || ""

    messages =
      Storage.get_messages(%{
        per_page: @per_page,
        offset: (page - 1) * @per_page,
        sort: sort,
        dir: dir,
        search: search
      })

    has_next = length(messages) > @per_page
    messages = Enum.take(messages, @per_page)

    {:noreply,
     assign(socket,
       messages: messages,
       page: page,
       sort: sort,
       dir: dir,
       search: search,
       has_next: has_next,
       base_params: %{"sort" => sort, "dir" => dir, "q" => search},
       current_path: URI.parse(uri).path
     )}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    params = %{"sort" => socket.assigns.sort, "dir" => socket.assigns.dir, "q" => q}
    {:noreply, push_patch(socket, to: "/admin/messages?" <> URI.encode_query(params))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current_path={@current_path} />
    <div class="max-w-7xl mx-auto px-4">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold text-gray-900">Message Log</h1>
        <.search_input name="q" value={@search} placeholder="Search model, key, message…" />
      </div>

      <div class="bg-white rounded-lg shadow overflow-x-auto">
        <table class="w-full text-sm">
          <thead>
            <tr class="text-left border-b">
              <.sort_header key={:timestamp} label="Time" sort_key={@sort} sort_dir={@dir} />
              <.sort_header key={:key_name} label="Key Name" sort_key={@sort} sort_dir={@dir} />
              <.sort_header key={:model} label="Model" sort_key={@sort} sort_dir={@dir} />
              <.sort_header key={:route} label="Route" sort_key={@sort} sort_dir={@dir} />
              <th class="px-4 py-3 text-gray-500">Message</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={msg <- @messages} class="border-b border-gray-100 hover:bg-gray-50">
              <td class="px-4 py-3 text-gray-500 whitespace-nowrap">
                {format_time(msg.timestamp)}
              </td>
              <td class="px-4 py-3 font-medium">{msg.key_name}</td>
              <td class="px-4 py-3 font-mono text-xs">{msg.model}</td>
              <td class="px-4 py-3 text-xs">{msg.route}</td>
              <td class="px-4 py-3 text-xs text-gray-600 max-w-md truncate">
                {msg.user_message}
              </td>
            </tr>
          </tbody>
        </table>
        <p :if={@messages == []} class="px-4 py-8 text-center text-gray-400">No messages found</p>
      </div>

      <.pagination page={@page} has_next={@has_next} base_params={@base_params} />
    </div>
    """
  end

  defp parse_page(nil), do: 1

  defp parse_page(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_time(_), do: ""
end
