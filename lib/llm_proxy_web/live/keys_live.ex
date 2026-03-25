defmodule LLMProxyWeb.KeysLive do
  use Phoenix.LiveView

  import LLMProxyWeb.AdminComponents

  alias LLMProxy.Storage

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, new_key: nil, page_title: "API Keys")}
  end

  @impl true
  def handle_params(params, uri, socket) do
    sort = params["sort"] || "name"
    dir = params["dir"] || "asc"
    keys = Storage.list_keys(%{sort: sort, dir: dir})

    {:noreply,
     assign(socket,
       keys: keys,
       sort: sort,
       dir: dir,
       current_path: URI.parse(uri).path
     )}
  end

  @impl true
  def handle_event("create_key", %{"name" => name}, socket) do
    case Storage.create_key(name) do
      {:ok, _key, raw_key} ->
        keys = Storage.list_keys(%{sort: socket.assigns.sort, dir: socket.assigns.dir})
        {:noreply, assign(socket, keys: keys, new_key: raw_key)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create key")}
    end
  end

  def handle_event("delete_key", %{"id" => id}, socket) do
    Storage.delete_key(id)
    keys = Storage.list_keys(%{sort: socket.assigns.sort, dir: socket.assigns.dir})
    {:noreply, assign(socket, keys: keys)}
  end

  def handle_event("dismiss_key", _, socket) do
    {:noreply, assign(socket, new_key: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current_path={@current_path} />
    <div class="max-w-7xl mx-auto px-4">
      <h1 class="text-2xl font-bold text-gray-900 mb-6">API Keys</h1>

      <div
        :if={@new_key}
        class="bg-green-50 border border-green-200 rounded-lg p-4 mb-6 flex items-center justify-between"
      >
        <div>
          <p class="text-sm text-green-800 font-medium">
            Key created — copy it now, it won't be shown again:
          </p>
          <code class="text-sm font-mono text-green-900 select-all">{@new_key}</code>
        </div>
        <button phx-click="dismiss_key" class="text-green-600 hover:text-green-800 text-sm">
          Dismiss
        </button>
      </div>

      <form phx-submit="create_key" class="flex gap-2 mb-6">
        <input
          type="text"
          name="name"
          placeholder="Key name"
          required
          class="px-3 py-2 border border-gray-300 rounded-md shadow-sm text-sm focus:ring-2 focus:ring-blue-500 focus:outline-none"
        />
        <button
          type="submit"
          class="px-4 py-2 bg-blue-600 text-white text-sm rounded-md hover:bg-blue-700"
        >
          Create Key
        </button>
      </form>

      <div class="bg-white rounded-lg shadow overflow-x-auto">
        <table class="w-full text-sm">
          <thead>
            <tr class="text-left border-b">
              <.sort_header key={:name} label="Name" sort_key={@sort} sort_dir={@dir} />
              <.sort_header
                key={:input_tokens}
                label="Input"
                sort_key={@sort}
                sort_dir={@dir}
                class="text-right"
              />
              <.sort_header
                key={:output_tokens}
                label="Output"
                sort_key={@sort}
                sort_dir={@dir}
                class="text-right"
              />
              <.sort_header
                key={:cache_read_tokens}
                label="Cache Read"
                sort_key={@sort}
                sort_dir={@dir}
                class="text-right"
              />
              <th class="px-4 py-3 text-gray-500 text-right">Spend</th>
              <th class="px-4 py-3 text-gray-500">4h Input Quota</th>
              <th class="px-4 py-3 text-gray-500">Models</th>
              <th class="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={key <- @keys} class="border-b border-gray-100 hover:bg-gray-50">
              <td class="px-4 py-3 font-medium">{key.name}</td>
              <td class="px-4 py-3 text-right font-mono text-xs">
                {format_tokens(key.input_tokens)}
              </td>
              <td class="px-4 py-3 text-right font-mono text-xs">
                {format_tokens(key.output_tokens)}
              </td>
              <td class="px-4 py-3 text-right font-mono text-xs">
                {format_tokens(key.cache_read_tokens)}
              </td>
              <td class="px-4 py-3 text-right font-mono text-xs">
                {format_usd(key.total_spend_usd)}
              </td>
              <td class="px-4 py-3 text-right text-xs">{key.quota_4h_input || "∞"}</td>
              <td class="px-4 py-3 text-xs text-gray-500">{format_models(key.allowed_models)}</td>
              <td class="px-4 py-3 text-right">
                <button
                  phx-click="delete_key"
                  phx-value-id={key.id}
                  data-confirm={"Delete key '#{key.name}'?"}
                  class="text-red-600 hover:text-red-800 text-xs"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
        <p :if={@keys == []} class="px-4 py-8 text-center text-gray-400">No API keys</p>
      </div>
    </div>
    """
  end

  defp format_tokens(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_tokens(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  defp format_tokens(0), do: "0"
  defp format_tokens(n), do: to_string(n)

  defp format_usd(nil), do: "—"
  defp format_usd(n) when n == 0.0, do: "$0"
  defp format_usd(n) when is_float(n) and n >= 1.0, do: "$#{:erlang.float_to_binary(n, decimals: 2)}"
  defp format_usd(n) when is_float(n), do: "$#{:erlang.float_to_binary(n, decimals: 4)}"
  defp format_usd(n) when is_number(n), do: format_usd(n / 1)

  defp format_models(nil), do: "all"
  defp format_models([]), do: "all"
  defp format_models(models), do: Enum.join(models, ", ")
end
