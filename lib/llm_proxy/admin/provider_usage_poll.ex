if Code.ensure_loaded?(Incant) and Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule LLMProxy.Admin.ProviderUsagePoll do
    @moduledoc """
    LiveView hook that reloads the Provider Usage dashboard at a fixed interval.

    Add this hook to the Incant `live_session`. The default interval is one
    minute. Configure `:admin_provider_usage_poll_interval_ms` to change it.
    """

    import Phoenix.Component, only: [assign: 3]
    import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, push_patch: 2]

    @message :llm_proxy_provider_usage_poll
    @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
            {:cont, Phoenix.LiveView.Socket.t()}
    def on_mount(:default, _params, _session, socket) do
      socket =
        socket
        |> assign(:llm_proxy_usage_poll_interval_ms, interval_ms())
        |> assign(:llm_proxy_usage_poll_timer, nil)
        |> assign(:llm_proxy_usage_poll_token, nil)
        |> assign(:llm_proxy_usage_poll_uri, nil)
        |> assign(:llm_proxy_usage_dashboard, false)
        |> attach_hook({__MODULE__, :params}, :handle_params, &handle_params/3)
        |> attach_hook({__MODULE__, :info}, :handle_info, &handle_info/2)

      {:cont, socket}
    end

    @doc false
    @spec provider_usage_dashboard?(map()) :: boolean()
    def provider_usage_dashboard?(params), do: params["dashboard"] == "provider_usage"

    @doc false
    @spec interval_ms() :: pos_integer()
    def interval_ms, do: LLMProxy.Config.admin_provider_usage_poll_interval_ms()

    defp handle_params(params, uri, socket) do
      dashboard? = provider_usage_dashboard?(params)

      socket =
        socket
        |> assign(:llm_proxy_usage_poll_uri, local_uri(uri))
        |> assign(:llm_proxy_usage_dashboard, dashboard?)
        |> update_timer(dashboard? and connected?(socket))

      {:cont, socket}
    end

    defp handle_info(
           {@message, token},
           %{assigns: %{llm_proxy_usage_poll_token: token}} = socket
         ) do
      socket =
        socket
        |> clear_timer()
        |> schedule()
        |> push_patch(to: socket.assigns.llm_proxy_usage_poll_uri, replace: true)

      {:halt, socket}
    end

    defp handle_info({@message, _stale_token}, socket), do: {:halt, socket}
    defp handle_info(_message, socket), do: {:cont, socket}

    defp update_timer(%{assigns: %{llm_proxy_usage_poll_timer: nil}} = socket, true),
      do: schedule(socket)

    defp update_timer(socket, true), do: socket
    defp update_timer(socket, false), do: cancel_timer(socket)

    defp schedule(socket) do
      token = make_ref()

      timer =
        Process.send_after(
          self(),
          {@message, token},
          socket.assigns.llm_proxy_usage_poll_interval_ms
        )

      socket
      |> assign(:llm_proxy_usage_poll_timer, timer)
      |> assign(:llm_proxy_usage_poll_token, token)
    end

    defp cancel_timer(%{assigns: %{llm_proxy_usage_poll_timer: nil}} = socket), do: socket

    defp cancel_timer(socket) do
      Process.cancel_timer(socket.assigns.llm_proxy_usage_poll_timer, async: true, info: false)
      clear_timer(socket)
    end

    defp clear_timer(socket) do
      socket
      |> assign(:llm_proxy_usage_poll_timer, nil)
      |> assign(:llm_proxy_usage_poll_token, nil)
    end

    defp local_uri(uri) do
      case URI.parse(uri) do
        %URI{path: path, query: nil} -> path || "/"
        %URI{path: path, query: query} -> "#{path || "/"}?#{query}"
      end
    end
  end
end
