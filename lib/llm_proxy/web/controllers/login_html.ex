if Code.ensure_loaded?(Phoenix.Component) do
  defmodule LLMProxy.Web.LoginHTML do
    @moduledoc false

    use Phoenix.Component

    def index(assigns) do
      ~H"""
      <div class="min-h-screen flex items-center justify-center bg-gray-50">
        <div class="max-w-sm w-full space-y-6">
          <h2 class="text-2xl font-bold text-center text-gray-900">LLM Proxy Admin</h2>
          <form method="post" action="/admin/login" class="space-y-4">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <div>
              <input
                type="password"
                name="password"
                placeholder="Master key"
                autofocus
                class="w-full px-3 py-2 border border-gray-300 rounded-md shadow-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
              />
            </div>
            <button
              type="submit"
              class="w-full py-2 px-4 bg-blue-600 text-white rounded-md hover:bg-blue-700"
            >
              Sign in
            </button>
            <p :if={@error} class="text-red-600 text-sm text-center">{@error}</p>
          </form>
        </div>
      </div>
      """
    end
  end
end
