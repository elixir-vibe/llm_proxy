defmodule LLMProxy.HTTP.Routes.Setup do
  @moduledoc """
  Optional setup-helper routes for install scripts, model lists, and client configuration snippets.
  """
  use Plug.Router

  alias LLMProxy.Config
  alias LLMProxy.Providers.Registry
  alias LLMProxy.Storage

  defmodule Auth do
    @moduledoc """
    Parsed setup endpoint authentication.
    """

    defstruct [:api_key]

    @type t :: %__MODULE__{api_key: String.t()}
  end

  plug(:match)
  plug(:dispatch)

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
      sorted_models = allowed_models(api_key)

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
      send_json(conn, 200, %{"PROVIDER_API_KEY" => key_param})
    end)
  end

  get "/extension" do
    with_auth(conn, fn key_param, api_key ->
      models_json =
        api_key
        |> allowed_models()
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

    with {:ok, %Auth{} = auth} <-
           parse_auth(conn.query_params, get_req_header(conn, "authorization")),
         api_key when not is_nil(api_key) <- Storage.find_key(auth.api_key) do
      fun.(auth.api_key, api_key)
    else
      _ -> send_json(conn, 401, %{error: "Invalid API key"})
    end
  end

  defp parse_auth(query_params, auth_headers) do
    key = query_params["key"] || bearer_token(auth_headers)

    if is_binary(key) and key != "" do
      {:ok, %Auth{api_key: key}}
    else
      {:error, "Invalid API key"}
    end
  end

  defp bearer_token(["Bearer " <> token | _]), do: token
  defp bearer_token([_ | rest]), do: bearer_token(rest)
  defp bearer_token([]), do: nil

  defp allowed_models(api_key) do
    Registry.all_models()
    |> filter_models(api_key.allowed_models)
    |> Enum.sort(&model_before?/2)
  end

  defp filter_models(models, nil), do: models
  defp filter_models(models, allowed), do: Enum.filter(models, &(&1.id in allowed))

  defp model_before?(a, b) do
    a_versioned = Regex.match?(~r/\d{8}$/, a.id)
    b_versioned = Regex.match?(~r/\d{8}$/, b.id)

    cond do
      a_versioned and not b_versioned -> true
      not a_versioned and b_versioned -> false
      true -> a.id <= b.id
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
