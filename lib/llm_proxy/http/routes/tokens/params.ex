defmodule LLMProxy.HTTP.Routes.Tokens.Params do
  @moduledoc false

  defmodule Create do
    @moduledoc false
    defstruct [:provider, :kind, :token, :label, :proxy]

    @type t :: %__MODULE__{
            provider: String.t(),
            kind: String.t(),
            token: String.t(),
            label: String.t() | nil,
            proxy: String.t() | nil
          }
  end

  defmodule Update do
    @moduledoc false
    defstruct [:enabled, :proxy, update_enabled?: false, update_proxy?: false]

    @type t :: %__MODULE__{
            enabled: boolean() | nil,
            proxy: String.t() | nil,
            update_enabled?: boolean(),
            update_proxy?: boolean()
          }
  end

  @spec parse_create(map()) :: {:ok, Create.t()} | {:error, String.t()}
  def parse_create(%{"provider" => provider, "kind" => kind, "token" => token} = body)
      when is_binary(provider) and provider != "" and is_binary(kind) and kind != "" and
             is_binary(token) and token != "" do
    {:ok,
     %Create{
       provider: provider,
       kind: kind,
       token: token,
       label: body["label"],
       proxy: body["proxy"]
     }}
  end

  def parse_create(_body), do: {:error, "provider, kind, and token are required"}

  @spec parse_update(map()) :: {:ok, Update.t()} | {:error, String.t()}
  def parse_update(body) do
    update_enabled? = Map.has_key?(body, "enabled")
    update_proxy? = Map.has_key?(body, "proxy")

    cond do
      not update_enabled? and not update_proxy? ->
        {:error, "At least one of enabled or proxy is required"}

      update_enabled? and not is_boolean(body["enabled"]) ->
        {:error, "enabled must be a boolean"}

      true ->
        {:ok,
         %Update{
           enabled: body["enabled"],
           proxy: body["proxy"],
           update_enabled?: update_enabled?,
           update_proxy?: update_proxy?
         }}
    end
  end
end
