defmodule LLMProxy.TokenPool.Server do
  @moduledoc """
  Manages provider tokens with rate-limit cooldowns.

  Picks tokens using the configured affinity or fill-first strategy.
  Priority: OAuth tokens first, then API keys as fallback.
  """

  use GenServer

  require Logger

  alias LLMProxy.Provider.Credential
  alias LLMProxy.Provider.TokenCodec
  alias LLMProxy.Schemas.ProviderToken
  alias LLMProxy.Storage.Repo

  import Bitwise
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
    Logger.warning("Token #{id} marked as rate-limited")
    GenServer.cast(__MODULE__, {:mark_rate_limited, id, cooldown_ms})
  end

  def mark_rate_limited(%Credential{id: id}, cooldown_ms) do
    Logger.warning("Token #{id} marked as rate-limited")
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
      {:error, reason} -> {:reply, {:error, reason}, state}
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
      {:error, _reason} = error -> error
      oauth_status -> pick_api_key_after_oauth(provider, user_id, state, oauth_status)
    end
  end

  defp pick_api_key_after_oauth(provider, user_id, state, oauth_status) do
    case do_pick_by_kind(provider, "api-key", user_id, state) do
      {:ok, token} -> {:ok, token}
      {:error, _reason} = error -> error
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
    strategy = LLMProxy.Config.token_selection_strategy()
    tokens = get_enabled_tokens(provider, kind, strategy)

    case tokens do
      [] -> :none
      tokens -> pick_available(tokens, user_id, state, strategy)
    end
  end

  defp pick_available(tokens, user_id, state, strategy) do
    now = System.monotonic_time(:millisecond)

    tokens
    |> ordered_candidates(strategy, user_id)
    |> Enum.find(fn token ->
      case Map.get(state.cooldowns, token.id) do
        nil -> true
        expires_at -> now >= expires_at
      end
    end)
    |> case do
      nil -> :all_rate_limited
      token -> TokenCodec.for_provider(token)
    end
  end

  defp ordered_candidates(tokens, :fill_first, _user_id), do: tokens

  defp ordered_candidates(tokens, :affinity, user_id) do
    pool_size = length(tokens)
    start_idx = pick_index(user_id, pool_size)

    tokens
    |> Stream.cycle()
    |> Stream.drop(start_idx)
    |> Stream.take(pool_size)
  end

  defp pick_index(_user_id, pool_size) when pool_size <= 1, do: 0

  defp pick_index(user_id, pool_size) do
    rem(fnv1a(user_id), pool_size)
  end

  defp fnv1a(str) do
    str
    |> :binary.bin_to_list()
    |> Enum.reduce(0x811C9DC5, fn byte, hash ->
      hash
      |> bxor(byte)
      |> Kernel.*(0x01000193)
      |> band(0xFFFFFFFF)
    end)
  end

  defp get_enabled_tokens(provider, kind, :affinity),
    do: query_enabled_tokens(provider, kind) |> order_by([t], asc: t.id) |> Repo.all()

  defp get_enabled_tokens(provider, kind, :fill_first),
    do:
      query_enabled_tokens(provider, kind)
      |> order_by([t], desc: t.priority, asc: t.id)
      |> Repo.all()

  defp query_enabled_tokens(provider, kind) do
    where(
      ProviderToken,
      [t],
      t.provider == ^provider and t.kind == ^kind and t.enabled == true
    )
  end
end
