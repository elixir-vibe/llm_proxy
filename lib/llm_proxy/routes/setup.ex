defmodule LLMProxy.Routes.Setup do
  @moduledoc false
  use Plug.Router

  alias LLMProxy.Config
  alias LLMProxy.Providers.Registry
  alias LLMProxy.Storage

  plug :match
  plug :dispatch

  get "/install.sh" do
    script_path = Application.app_dir(:llm_proxy, "priv/scripts/install.sh")

    case File.read(script_path) do
      {:ok, script} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, String.replace(script, "__PROXY_URL__", base_url(conn)))

      {:error, _} ->
        send_json(conn, 404, %{error: "Install script not found"})
    end
  end

  get "/models" do
    send_json(conn, 200, Registry.all_models())
  end

  get "/config" do
    with_auth(conn, fn key_param, api_key ->
      all_models = Registry.all_models()

      allowed_models =
        case api_key.allowed_models do
          nil -> all_models
          allowed -> Enum.filter(all_models, &(&1.id in allowed))
        end

      sorted_models =
        Enum.sort(allowed_models, fn a, b ->
          a_versioned = Regex.match?(~r/\d{8}$/, a.id)
          b_versioned = Regex.match?(~r/\d{8}$/, b.id)

          cond do
            a_versioned and not b_versioned -> true
            not a_versioned and b_versioned -> false
            true -> a.id <= b.id
          end
        end)

      send_json(conn, 200, %{
        providers: %{
          "llm-proxy" => %{
            baseUrl: base_url(conn),
            apiKey: key_param,
            api: "anthropic-messages",
            models: sorted_models
          }
        }
      })
    end)
  end

  get "/env" do
    with_auth(conn, fn key_param, _api_key ->
      env = %{"PROVIDER_API_KEY" => key_param}

      env =
        case Config.exa_api_key() do
          key when key != "" -> Map.put(env, "EXA_API_KEY", key)
          _ -> env
        end

      env =
        case Config.context7_api_key() do
          key when key != "" -> Map.put(env, "CONTEXT7_API_KEY", key)
          _ -> env
        end

      send_json(conn, 200, env)
    end)
  end

  get "/extension" do
    with_auth(conn, fn key_param, api_key ->
      all_models = Registry.all_models()

      allowed_models =
        case api_key.allowed_models do
          nil -> all_models
          allowed -> Enum.filter(all_models, &(&1.id in allowed))
        end

      models_json =
        allowed_models
        |> Jason.encode!(pretty: true)
        |> String.replace("\n", "\n    ")

      extension = """
      import type { ExtensionAPI } from '@dannote/pi-agent'

      export default function(pi: ExtensionAPI) {
        pi.registerProvider('llm-proxy', {
          baseUrl: '#{base_url(conn)}',
          apiKey: '#{key_param}',
          api: 'anthropic-messages',
          models: #{models_json}
        })
      }
      """

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, extension)
    end)
  end

  match _ do
    send_json(conn, 404, %{error: "Not found"})
  end

  defp with_auth(conn, fun) do
    conn = fetch_query_params(conn)

    key_param =
      conn.query_params["key"] ||
        case get_req_header(conn, "authorization") do
          ["Bearer " <> token] -> token
          _ -> nil
        end

    case key_param && Storage.find_key(key_param) do
      nil -> send_json(conn, 401, %{error: "Invalid API key"})
      api_key -> fun.(key_param, api_key)
    end
  end

  defp base_url(conn) do
    case Config.public_url() do
      url when url != "" ->
        url

      _ ->
        case get_req_header(conn, "host") do
          [host | _] -> "https://#{host}"
          _ -> "http://localhost:4000"
        end
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
