defmodule LLMProxy.HTTP.Routes.Setup.Params do
  @moduledoc false

  defmodule Auth do
    @moduledoc false
    defstruct [:api_key]

    @type t :: %__MODULE__{api_key: String.t()}
  end

  @spec parse_auth(map(), [String.t()]) :: {:ok, Auth.t()} | {:error, String.t()}
  def parse_auth(query_params, auth_headers) do
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
end
