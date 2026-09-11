defmodule LLMProxy.Protocol.CodexAttribution do
  @moduledoc "Validates Codex attribution at the HTTP boundary and scopes upstream identities."

  alias LLMProxy.Protocol.Request.Error

  defmodule Turn do
    @moduledoc false
    use JSONCodec, strict: true, fast_path: :json

    defstruct [
      :session_id,
      :thread_id,
      :turn_id,
      :window_id,
      :request_kind,
      :turn_started_at_unix_ms,
      :installation_id
    ]

    @type t :: %__MODULE__{
            session_id: String.t() | nil,
            thread_id: String.t() | nil,
            turn_id: String.t() | nil,
            window_id: String.t() | nil,
            request_kind: String.t() | nil,
            turn_started_at_unix_ms: non_neg_integer() | nil,
            installation_id: String.t() | nil
          }
  end

  defmodule ClientMetadata do
    @moduledoc false
    use JSONCodec, strict: true, fast_path: :json

    defstruct [
      :session_id,
      :thread_id,
      :turn_id,
      :window_id,
      :installation_id,
      :turn_metadata,
      :originator
    ]

    @type t :: %__MODULE__{
            session_id: String.t() | nil,
            thread_id: String.t() | nil,
            turn_id: String.t() | nil,
            window_id: String.t() | nil,
            installation_id: String.t() | nil,
            turn_metadata: String.t() | nil,
            originator: String.t() | nil
          }

    codec(:window_id, as: "x-codex-window-id")
    codec(:installation_id, as: "x-codex-installation-id")
    codec(:turn_metadata, as: "x-codex-turn-metadata")
  end

  defmodule Headers do
    @moduledoc false
    use JSONCodec, strict: true, fast_path: :json

    defstruct [
      :session_id,
      :thread_id,
      :client_request_id,
      :window_id,
      :installation_id,
      :turn_metadata,
      :originator
    ]

    @type t :: %__MODULE__{
            session_id: String.t() | nil,
            thread_id: String.t() | nil,
            client_request_id: String.t() | nil,
            window_id: String.t() | nil,
            installation_id: String.t() | nil,
            turn_metadata: String.t() | nil,
            originator: String.t() | nil
          }

    codec(:session_id, as: "session-id")
    codec(:thread_id, as: "thread-id")
    codec(:client_request_id, as: "x-client-request-id")
    codec(:window_id, as: "x-codex-window-id")
    codec(:installation_id, as: "x-codex-installation-id")
    codec(:turn_metadata, as: "x-codex-turn-metadata")
  end

  @turn_fields ~w(session_id thread_id turn_id window_id request_kind turn_started_at_unix_ms installation_id)a
  @required_turn_fields @turn_fields -- [:installation_id]
  @identities ~w(session_id thread_id turn_id window_id installation_id)a
  @header_names ~w(session-id thread-id x-client-request-id x-codex-window-id x-codex-installation-id x-codex-turn-metadata originator)

  def normalize(body, headers) do
    case parse(body, headers) do
      {:ok, fields}
      when map_size(fields) == 0 or (map_size(fields) == 1 and is_map_key(fields, :originator)) ->
        {:ok, body}

      {:ok, fields} ->
        {:ok, Map.put(body, "client_metadata", render(fields))}

      {:error, _reason} ->
        {:error,
         Error.new("invalid_codex_attribution", "Invalid or conflicting Codex attribution")}
    end
  end

  @doc "Parses only allowlisted attribution fields; codec failures remain structured."
  def parse(body, headers) do
    with {:ok, client} <- decode_client(Map.get(body, "client_metadata", %{})),
         {:ok, header_map} <- unique_headers(headers),
         {:ok, header} <- Headers.from_map(header_map),
         {:ok, client_turn} <- decode_turn(client.turn_metadata),
         {:ok, header_turn} <- decode_turn(header.turn_metadata),
         {:ok, fields} <-
           merge_sources([
             present(client_turn),
             present(header_turn),
             client |> present() |> Map.delete(:turn_metadata),
             header |> present() |> Map.drop([:turn_metadata, :client_request_id])
           ]),
         :ok <- validate_client_request_id(header.client_request_id, fields),
         :ok <- validate_fields(fields, client.turn_metadata || header.turn_metadata) do
      {:ok, fields}
    end
  end

  def options(body, key_id) do
    {:ok, fields} = parse(body, [])
    legacy = if is_map(body["metadata"]), do: body["metadata"], else: %{}
    cache_key = body["prompt_cache_key"] || legacy["session_id"]

    fields =
      fields
      |> Map.put_new(:session_id, legacy["session_id"] || cache_key)
      |> Map.put_new(:thread_id, legacy["thread_id"])
      |> Map.new(fn {key, value} ->
        {key, if(key in @identities, do: scope(key_id, value), else: value)}
      end)

    [
      session_id: fields[:session_id],
      thread_id: fields[:thread_id],
      prompt_cache_key: scope(key_id, cache_key),
      codex_originator: fields[:originator],
      codex_turn_metadata: turn_options(fields)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp unique_headers(headers) do
    selected = Enum.filter(headers, fn {name, _value} -> name in @header_names end)
    map = Map.new(selected)

    if map_size(map) == length(selected),
      do: {:ok, map},
      else: {:error, :duplicate_attribution_header}
  end

  defp decode_client(value) when is_map(value), do: ClientMetadata.from_map(value)
  defp decode_client(_value), do: {:error, :invalid_client_metadata_shape}

  defp decode_turn(nil), do: {:ok, %Turn{}}

  defp decode_turn(value) when is_binary(value) and byte_size(value) <= 4_096 do
    Turn.decode(value)
  rescue
    FunctionClauseError -> {:error, :invalid_turn_metadata_shape}
  end

  defp decode_turn(_value), do: {:error, :oversized_turn_metadata}

  defp present(value),
    do: value |> Map.from_struct() |> Map.reject(fn {_key, value} -> is_nil(value) end)

  defp merge_sources(sources) do
    Enum.reduce_while(sources, {:ok, %{}}, fn source, {:ok, acc} ->
      if conflicting?(source, acc),
        do: {:halt, {:error, :conflicting_attribution}},
        else: {:cont, {:ok, Map.merge(acc, source)}}
    end)
  end

  defp conflicting?(source, acc) do
    Enum.any?(source, fn {key, value} -> Map.has_key?(acc, key) and acc[key] != value end)
  end

  defp validate_client_request_id(nil, _fields), do: :ok
  defp validate_client_request_id(_id, fields) when not is_map_key(fields, :thread_id), do: :ok
  defp validate_client_request_id(id, %{thread_id: id}), do: :ok
  defp validate_client_request_id(_id, _fields), do: {:error, :conflicting_client_request_id}

  defp validate_fields(fields, declared_turn) do
    complete? =
      if declared_turn ||
           Enum.any?(
             ~w(turn_id window_id request_kind turn_started_at_unix_ms)a,
             &Map.has_key?(fields, &1)
           ),
         do: Enum.all?(@required_turn_fields, &Map.has_key?(fields, &1)),
         else: true

    if complete? and Enum.all?(fields, &valid_field?/1),
      do: :ok,
      else: {:error, :invalid_attribution_fields}
  end

  defp valid_field?({:turn_started_at_unix_ms, value}), do: is_integer(value) and value >= 0

  defp valid_field?({key, value}) when is_binary(value) and byte_size(value) in 1..256 do
    if key in @identities,
      do: String.valid?(value) and not Regex.match?(~r/[\x00-\x20\x7f]/u, value),
      else: Regex.match?(~r/\A[\x21-\x7e]+\z/, value)
  end

  defp valid_field?(_field), do: false

  defp render(fields) do
    client = struct!(ClientMetadata, Map.drop(fields, [:request_kind, :turn_started_at_unix_ms]))

    client =
      if Map.has_key?(fields, :turn_id) do
        turn = struct!(Turn, Map.take(fields, @turn_fields))
        %{client | turn_metadata: Jason.encode!(dump(turn), escape: :unicode_safe)}
      else
        client
      end

    dump(client)
  end

  defp dump(value),
    do: value |> JSONCodec.dump() |> Map.reject(fn {_key, value} -> is_nil(value) end)

  defp turn_options(%{turn_id: _} = fields),
    do: Map.take(fields, @turn_fields -- [:session_id, :thread_id])

  defp turn_options(_fields), do: nil

  defp scope(key_id, identity) when is_binary(identity) and byte_size(identity) > 0 do
    :crypto.hash(:sha256, :erlang.term_to_binary({:llm_proxy_codex, key_id, identity}))
    |> Base.encode16(case: :lower)
  end

  defp scope(_key_id, _identity), do: nil
end
