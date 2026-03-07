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
