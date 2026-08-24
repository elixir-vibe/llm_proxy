if Code.ensure_loaded?(Incant) and Code.ensure_loaded?(Phoenix.LiveView.Router) do
  defmodule LLMProxy.Admin.Router do
    @moduledoc """
    Router helper for an Incant admin surface with live provider-usage polling.

    Use `llm_proxy_incant/3` in place of `Incant.Router.incant/3`. It mounts the
    same routes and adds the `LLMProxy.Admin.ProviderUsagePoll` hook.
    """

    defmacro __using__(_opts \\ []) do
      quote do
        import LLMProxy.Admin.Router
      end
    end

    defmacro llm_proxy_incant(path, admin_or_opts, opts \\ []) do
      if Keyword.keyword?(admin_or_opts) do
        registry_routes(path, admin_or_opts, opts)
      else
        local_routes(path, admin_or_opts, opts)
      end
    end

    defp registry_routes(path, admin_or_opts, opts) do
      registry = Keyword.fetch!(admin_or_opts, :registry)
      session_name = Keyword.get(opts, :as, :llm_proxy_incant)
      base_path = Keyword.get(opts, :base_path, path)
      root_path = if path == "", do: "/", else: path

      quote do
        scope alias: false do
          live_session unquote(session_name),
            session: %{
              "__incant__" => %Incant.Live.Session{
                source: {:registry, unquote(registry)},
                base_path: unquote(base_path)
              }
            },
            on_mount: [{LLMProxy.Admin.ProviderUsagePoll, :default}] do
            live(unquote(path <> "/:service"), Incant.Live.Admin, :index)
            live(unquote(path <> "/:service/dashboards"), Incant.Live.Admin, :dashboards)
            live(unquote(path <> "/:service/resources"), Incant.Live.Admin, :resources)
            live(unquote(path <> "/:service/datasets"), Incant.Live.Admin, :datasets)

            live(
              unquote(path <> "/:service/dashboards/:dashboard"),
              Incant.Live.Admin,
              :dashboard
            )

            live(unquote(path <> "/:service/datasets/:dataset"), Incant.Live.Admin, :dataset)
            live(unquote(path <> "/:service/resources/:resource"), Incant.Live.Admin, :resource)

            live(
              unquote(path <> "/:service/resources/:resource/new"),
              Incant.Live.Admin,
              :resource_new
            )

            live(
              unquote(path <> "/:service/resources/:resource/:id"),
              Incant.Live.Admin,
              :resource_detail
            )

            live(
              unquote(path <> "/:service/resources/:resource/:id/edit"),
              Incant.Live.Admin,
              :resource_edit
            )

            live(unquote(root_path), Incant.Live.Admin, :services)
          end
        end
      end
    end

    defp local_routes(path, admin, opts) do
      session_name = Keyword.get(opts, :as, :llm_proxy_incant)
      base_path = Keyword.get(opts, :base_path, path)

      quote do
        scope alias: false do
          live_session unquote(session_name),
            session: %{
              "__incant__" => %Incant.Live.Session{
                source: {:local, unquote(admin)},
                base_path: unquote(base_path)
              }
            },
            on_mount: [{LLMProxy.Admin.ProviderUsagePoll, :default}] do
            live(unquote(path), Incant.Live.Admin, :index)
            live(unquote(path <> "/dashboards"), Incant.Live.Admin, :dashboards)
            live(unquote(path <> "/resources"), Incant.Live.Admin, :resources)
            live(unquote(path <> "/datasets"), Incant.Live.Admin, :datasets)
            live(unquote(path <> "/dashboards/:dashboard"), Incant.Live.Admin, :dashboard)
            live(unquote(path <> "/datasets/:dataset"), Incant.Live.Admin, :dataset)
            live(unquote(path <> "/resources/:resource"), Incant.Live.Admin, :resource)
            live(unquote(path <> "/resources/:resource/new"), Incant.Live.Admin, :resource_new)

            live(
              unquote(path <> "/resources/:resource/:id"),
              Incant.Live.Admin,
              :resource_detail
            )

            live(
              unquote(path <> "/resources/:resource/:id/edit"),
              Incant.Live.Admin,
              :resource_edit
            )
          end
        end
      end
    end
  end
end
