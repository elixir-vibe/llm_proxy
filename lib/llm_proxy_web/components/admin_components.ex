defmodule LLMProxyWeb.AdminComponents do
  @moduledoc false

  use Phoenix.Component

  attr :current_path, :string, required: true

  def nav(assigns) do
    ~H"""
    <nav class="bg-white shadow mb-6">
      <div class="max-w-7xl mx-auto px-4">
        <div class="flex justify-between h-14">
          <div class="flex space-x-8">
            <div class="flex items-center">
              <span class="text-lg font-semibold text-gray-900">LLM Proxy</span>
            </div>
            <.nav_link path="/admin" current={@current_path} label="Dashboard" exact />
            <.nav_link path="/admin/keys" current={@current_path} label="API Keys" />
            <.nav_link path="/admin/tokens" current={@current_path} label="Token Pool" />
            <.nav_link path="/admin/messages" current={@current_path} label="Messages" />
            <.nav_link path="/admin/traces" current={@current_path} label="Traces" />
            <.nav_link path="/admin/models" current={@current_path} label="Models" />
          </div>
          <div class="flex items-center">
            <a href="/admin/logout" class="text-sm text-gray-500 hover:text-gray-700">Logout</a>
          </div>
        </div>
      </div>
    </nav>
    """
  end

  attr :key, :atom, required: true
  attr :label, :string, required: true
  attr :sort_key, :string, required: true
  attr :sort_dir, :string, required: true
  attr :class, :string, default: ""

  def sort_header(assigns) do
    active = to_string(assigns.key) == assigns.sort_key

    assigns =
      assigns
      |> assign(:active, active)
      |> assign(:next_dir, if(active && assigns.sort_dir == "asc", do: "desc", else: "asc"))

    ~H"""
    <th class={"px-4 py-3 #{@class}"}>
      <.link
        patch={"?" <> build_sort_query(@key, @next_dir)}
        class="group inline-flex items-center gap-1 text-gray-500 hover:text-gray-900"
      >
        {@label}
        <span class={["text-gray-300 group-hover:text-gray-400", @active && "!text-blue-500"]}>
          <svg
            :if={!@active || @sort_dir == "asc"}
            xmlns="http://www.w3.org/2000/svg"
            class="h-3.5 w-3.5"
            viewBox="0 0 20 20"
            fill="currentColor"
          >
            <path
              fill-rule="evenodd"
              d="M5.293 7.293a1 1 0 011.414 0L10 10.586l3.293-3.293a1 1 0 111.414 1.414l-4 4a1 1 0 01-1.414 0l-4-4a1 1 0 010-1.414z"
              clip-rule="evenodd"
            />
          </svg>
          <svg
            :if={@active && @sort_dir == "desc"}
            xmlns="http://www.w3.org/2000/svg"
            class="h-3.5 w-3.5"
            viewBox="0 0 20 20"
            fill="currentColor"
          >
            <path
              fill-rule="evenodd"
              d="M14.707 12.707a1 1 0 01-1.414 0L10 9.414l-3.293 3.293a1 1 0 01-1.414-1.414l4-4a1 1 0 011.414 0l4 4a1 1 0 010 1.414z"
              clip-rule="evenodd"
            />
          </svg>
        </span>
      </.link>
    </th>
    """
  end

  attr :page, :integer, required: true
  attr :has_next, :boolean, required: true
  attr :base_params, :map, default: %{}

  def pagination(assigns) do
    ~H"""
    <div class="flex justify-between items-center mt-4">
      <.link
        :if={@page > 1}
        patch={"?" <> build_page_query(@base_params, @page - 1)}
        class="px-3 py-1.5 text-sm bg-white border rounded-md hover:bg-gray-50"
      >
        ← Previous
      </.link>
      <span :if={@page <= 1} />
      <span class="text-sm text-gray-500">Page {@page}</span>
      <.link
        :if={@has_next}
        patch={"?" <> build_page_query(@base_params, @page + 1)}
        class="px-3 py-1.5 text-sm bg-white border rounded-md hover:bg-gray-50"
      >
        Next →
      </.link>
      <span :if={!@has_next} />
    </div>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :placeholder, :string, default: "Search…"
  attr :class, :string, default: ""

  def search_input(assigns) do
    ~H"""
    <form phx-change="search" phx-submit="search" class={@class}>
      <input
        type="text"
        name={@name}
        value={@value}
        placeholder={@placeholder}
        phx-debounce="300"
        class="px-3 py-2 border border-gray-300 rounded-md shadow-sm text-sm focus:ring-2 focus:ring-blue-500 focus:outline-none w-64"
      />
    </form>
    """
  end

  defp build_sort_query(key, dir) do
    URI.encode_query(%{"sort" => "#{key}", "dir" => dir})
  end

  defp build_page_query(base, page) do
    base |> Map.put("page", page) |> URI.encode_query()
  end

  attr :path, :string, required: true
  attr :current, :string, required: true
  attr :label, :string, required: true
  attr :exact, :boolean, default: false

  defp nav_link(assigns) do
    active =
      if assigns.exact,
        do: assigns.current == assigns.path,
        else: String.starts_with?(assigns.current, assigns.path)

    assigns = assign(assigns, :active, active)

    ~H"""
    <a
      href={@path}
      class={[
        "inline-flex items-center px-1 pt-1 border-b-2 text-sm font-medium",
        if(@active,
          do: "border-blue-500 text-gray-900",
          else: "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"
        )
      ]}
    >
      {@label}
    </a>
    """
  end
end
