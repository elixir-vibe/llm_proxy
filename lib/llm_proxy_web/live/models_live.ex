defmodule LLMProxyWeb.ModelsLive do
  use Phoenix.LiveView

  import LLMProxyWeb.AdminComponents

  alias LLMProxy.Providers.Registry

  @impl true
  def mount(_params, _session, socket) do
    providers =
      Registry.list_providers()
      |> Enum.map(fn {name, module} ->
        models = module.models()
        %{name: name, count: length(models), models: Enum.sort(models)}
      end)
      |> Enum.sort_by(& &1.name)

    total = Enum.reduce(providers, 0, fn p, acc -> acc + p.count end)

    {:ok, assign(socket, providers: providers, total: total, page_title: "Models")}
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
      <div class="flex items-center gap-3 mb-6">
        <h1 class="text-2xl font-bold text-gray-900">Models</h1>
        <span class="text-sm text-gray-500">{@total} total</span>
      </div>

      <div :for={provider <- @providers} class="bg-white rounded-lg shadow mb-6">
        <div class="px-4 py-3 border-b flex items-center justify-between">
          <h2 class="font-semibold text-gray-900">{provider.name}</h2>
          <span class="text-sm text-gray-500">{provider.count} models</span>
        </div>
        <div class="px-4 py-3">
          <div class="flex flex-wrap gap-2">
            <span
              :for={model <- provider.models}
              class="px-2 py-1 bg-gray-100 text-gray-700 rounded text-xs font-mono"
            >
              {model}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
