defmodule LLMProxy.TokenPool.Server do
  @moduledoc """
  Manages provider tokens with rate-limit cooldowns.

  Picks tokens using FNV-1a hash for cache affinity.
  Priority: OAuth tokens first, then API keys as fallback.
  """

  use GenServer

  alias LLMProxy.Schemas.ProviderToken
  alias LLMProxy.Storage.Repo
  alias LLMProxy.TokenPool.Picker

  import Ecto.Query

  defmodule State do
    @moduledoc """
    Runtime state for provider-token cooldown timestamps.
    """
    defstruct cooldowns: %{}
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %State{}, name: __MODULE__)
  end

  def pick_token(provider, user_id \\ "") do
    GenServer.call(__MODULE__, {:pick_token, provider, user_id})
  end

  def pick_token_by_kind(provider, kind, user_id \\ "") do
    GenServer.call(__MODULE__, {:pick_token_by_kind, provider, kind, user_id})
  end

  def mark_rate_limited(token, cooldown_ms \\ LLMProxy.Config.token_cooldown_ms())

  def mark_rate_limited(%ProviderToken{id: id}, cooldown_ms) do
    GenServer.cast(__MODULE__, {:mark_rate_limited, id, cooldown_ms})
  end

  def clear_rate_limits do
    GenServer.cast(__MODULE__, :clear_rate_limits)
  end

  # Callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:pick_token, provider, user_id}, _from, state) do
    result = do_pick_with_fallback(provider, user_id, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:pick_token_by_kind, provider, kind, user_id}, _from, state) do
    case do_pick_by_kind(provider, kind, user_id, state) do
      {:ok, token} -> {:reply, {:ok, token}, state}
      :none -> {:reply, {:error, :no_tokens}, state}
      :all_rate_limited -> {:reply, {:error, :all_rate_limited}, state}
    end
  end

  @impl true
  def handle_cast({:mark_rate_limited, token_id, cooldown_ms}, state) do
    cooldowns =
      Map.put(state.cooldowns, token_id, System.monotonic_time(:millisecond) + cooldown_ms)

    {:noreply, %{state | cooldowns: cooldowns}}
  end

  @impl true
  def handle_cast(:clear_rate_limits, state) do
    {:noreply, %{state | cooldowns: %{}}}
  end

  # Private

  defp do_pick_with_fallback(provider, user_id, state) do
    case do_pick_oauth(provider, user_id, state) do
      {:ok, token} -> {:ok, token}
      oauth_status -> pick_api_key_after_oauth(provider, user_id, state, oauth_status)
    end
  end

  defp pick_api_key_after_oauth(provider, user_id, state, oauth_status) do
    case do_pick_by_kind(provider, "api-key", user_id, state) do
      {:ok, token} -> {:ok, token}
      api_key_status -> fallback_error(oauth_status, api_key_status)
    end
  end

  defp fallback_error(:all_rate_limited, :none), do: {:error, :all_rate_limited}
  defp fallback_error(_oauth_status, :none), do: {:error, :no_tokens}
  defp fallback_error(_oauth_status, :all_rate_limited), do: {:error, :all_rate_limited}

  defp do_pick_oauth(provider, user_id, state) do
    do_pick_by_kind(provider, "oauth", user_id, state)
  end

  defp do_pick_by_kind(provider, kind, user_id, state) do
    tokens = get_enabled_tokens(provider, kind)

    case tokens do
      [] -> :none
      tokens -> pick_available(tokens, user_id, state)
    end
  end

  defp pick_available(tokens, user_id, state) do
    now = System.monotonic_time(:millisecond)
    start_idx = Picker.pick_index(user_id, length(tokens))

    tokens
    |> Stream.cycle()
    |> Stream.drop(start_idx)
    |> Stream.take(length(tokens))
    |> Enum.find(fn token ->
      case Map.get(state.cooldowns, token.id) do
        nil -> true
        expires_at -> now >= expires_at
      end
    end)
    |> case do
      nil -> :all_rate_limited
      token -> {:ok, token}
    end
  end

  defp get_enabled_tokens(provider, kind) do
    ProviderToken
    |> where([t], t.provider == ^provider and t.kind == ^kind and t.enabled == true)
    |> order_by([t], asc: t.id)
    |> Repo.all()
  end
end
