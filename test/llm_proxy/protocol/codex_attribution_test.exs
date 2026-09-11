defmodule LLMProxy.Protocol.CodexAttributionTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Protocol.{CodexAttribution, Request}
  alias LLMProxy.Providers.OpenAICodex

  defp turn do
    %{
      "session_id" => "session-1",
      "thread_id" => "thread-1",
      "turn_id" => "turn-1",
      "window_id" => "window-1",
      "request_kind" => "turn",
      "turn_started_at_unix_ms" => 1_800_000_000_000,
      "installation_id" => "installation-1"
    }
  end

  defp headers do
    [
      {"session-id", "session-1"},
      {"thread-id", "thread-1"},
      {"x-client-request-id", "thread-1"},
      {"originator", "pi"},
      {"x-codex-turn-metadata", Jason.encode!(turn())}
    ]
  end

  defp client_metadata do
    %{
      "session_id" => "session-1",
      "thread_id" => "thread-1",
      "turn_id" => "turn-1",
      "x-codex-window-id" => "window-1",
      "x-codex-installation-id" => "installation-1",
      "x-codex-turn-metadata" => Jason.encode!(turn())
    }
  end

  defp token do
    payload = %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "test-account"}}
    %{token: "header.#{Base.url_encode64(Jason.encode!(payload), padding: false)}.signature"}
  end

  test "Pi Chat headers and Responses client metadata reach all upstream transports" do
    model = ReqLLM.model!("openai_codex:gpt-6-astra")

    for {protocol, body} <- [
          {:openai_chat, %{"messages" => [%{"role" => "user", "content" => "hello"}]}},
          {:openai_responses,
           %{
             "input" => [%{"role" => "user", "content" => "hello"}],
             "client_metadata" => client_metadata()
           }}
        ] do
      body = Map.merge(body, %{"model" => model.id, "prompt_cache_key" => "separate-cache"})
      {:ok, request} = Request.parse(protocol, body, headers())
      opts = OpenAICodex.generation_opts(request, token(), "key-1", true)
      context = %ReqLLM.Context{messages: request.messages}
      {:ok, ws} = ReqLLM.Providers.OpenAICodex.attach_websocket_stream(model, context, opts)
      {:ok, sse} = ReqLLM.Providers.OpenAICodex.attach_stream(model, context, opts, nil)

      {:ok, http} =
        ReqLLM.Providers.OpenAICodex.prepare_request(
          :chat,
          model,
          context,
          OpenAICodex.generation_opts(request, token(), "key-1", false)
        )

      [frame] = ws.initial_messages

      for {wire_headers, wire_body} <- [
            {Map.new(ws.headers), Jason.decode!(frame)},
            {Map.new(sse.headers), Jason.decode!(sse.body)},
            {http.headers, Jason.decode!(ReqLLM.Providers.OpenAICodex.encode_body(http).body)}
          ] do
        client = wire_body["client_metadata"]
        encoded = client["x-codex-turn-metadata"]
        scoped = Jason.decode!(encoded)
        assert List.wrap(wire_headers["x-codex-turn-metadata"]) == [encoded]
        assert List.wrap(wire_headers["session-id"]) == [scoped["session_id"]]
        assert List.wrap(wire_headers["thread-id"]) == [scoped["thread_id"]]
        assert List.wrap(wire_headers["originator"]) == ["pi"]
        assert client["turn_id"] == scoped["turn_id"]
        assert client["x-codex-window-id"] == scoped["window_id"]
        assert client["x-codex-installation-id"] == scoped["installation_id"]
        assert scoped["request_kind"] == "turn"
        assert scoped["turn_started_at_unix_ms"] == turn()["turn_started_at_unix_ms"]
        assert byte_size(scoped["session_id"]) == 64
        refute scoped["session_id"] == "session-1"
        refute wire_body["prompt_cache_key"] == scoped["session_id"]
      end
    end
  end

  test "scoping is stable across continuations and isolated by API key" do
    {:ok, body} = CodexAttribution.normalize(%{}, headers())
    first = CodexAttribution.options(body, "key-1")
    assert first == CodexAttribution.options(body, "key-1")
    second_key = CodexAttribution.options(body, "key-2")
    refute first[:session_id] == second_key[:session_id]
    refute first[:codex_turn_metadata][:turn_id] == second_key[:codex_turn_metadata][:turn_id]

    assert first[:codex_turn_metadata][:turn_started_at_unix_ms] ==
             second_key[:codex_turn_metadata][:turn_started_at_unix_ms]

    changed = Map.put(turn(), "turn_id", "turn-2")

    {:ok, next_body} =
      CodexAttribution.normalize(%{}, [{"x-codex-turn-metadata", Jason.encode!(changed)}])

    next = CodexAttribution.options(next_body, "key-1")
    assert next[:session_id] == first[:session_id]
    assert next[:thread_id] == first[:thread_id]
    refute next[:codex_turn_metadata][:turn_id] == first[:codex_turn_metadata][:turn_id]
  end

  test "normalization is idempotent and ignores untrusted extra fields" do
    client = Map.put(client_metadata(), "authorization", "secret")

    {:ok, body} =
      CodexAttribution.normalize(
        %{"client_metadata" => client},
        headers() ++ [{"authorization", "Bearer secret"}]
      )

    assert {:ok, ^body} = CodexAttribution.normalize(body, [])
    refute inspect(body) =~ "secret"
  end

  test "JSONCodec rejects incorrectly typed payloads with structured errors" do
    assert {:error, %JSONCodec.Error{}} =
             CodexAttribution.parse(%{"client_metadata" => %{"session_id" => 123}}, [])

    assert {:error, %JSONCodec.Error{}} =
             CodexAttribution.parse(%{"client_metadata" => %{session_id: "session"}}, [])
  end

  test "rejects conflicting copies and duplicate identity headers" do
    for {body, input_headers} <- [
          {%{"client_metadata" => Map.put(client_metadata(), "session_id", "other")}, headers()},
          {%{}, [{"thread-id", "other"} | headers()]},
          {%{}, [{"session-id", "session-1"} | headers()]},
          {%{},
           List.keyreplace(headers(), "x-client-request-id", 0, {"x-client-request-id", "other"})}
        ] do
      assert {:error, %Request.Error{code: "invalid_codex_attribution"}} =
               CodexAttribution.normalize(body, input_headers)
    end
  end

  test "rejects malformed, partial, oversized and unsafe turn metadata" do
    for value <- [
          "{",
          "{}",
          "null",
          "[]",
          String.duplicate("x", 4_097),
          Jason.encode!(%{"turn_id" => "turn"}),
          Jason.encode!(Map.put(turn(), "turn_started_at_unix_ms", -1)),
          Jason.encode!(Map.put(turn(), "session_id", "bad\r\nheader")),
          Jason.encode!(Map.put(turn(), "request_kind", ""))
        ] do
      assert {:error, %Request.Error{code: "invalid_codex_attribution"}} =
               CodexAttribution.normalize(%{}, [{"x-codex-turn-metadata", value}])
    end
  end

  test "Unicode identities become consistent ASCII identities after scoping" do
    unicode =
      Map.merge(turn(), %{"session_id" => "сессия", "thread_id" => "ветка", "turn_id" => "ход"})

    {:ok, body} =
      CodexAttribution.normalize(%{}, [
        {"x-codex-turn-metadata", Jason.encode!(unicode, escape: :unicode_safe)}
      ])

    options = CodexAttribution.options(body, "key")
    assert Regex.match?(~r/\A[0-9a-f]{64}\z/, options[:session_id])
    assert Regex.match?(~r/\A[0-9a-f]{64}\z/, options[:codex_turn_metadata][:turn_id])
  end

  test "does not invent a turn for legacy requests or standalone client request IDs" do
    body = %{"prompt_cache_key" => "cache"}
    assert {:ok, ^body} = CodexAttribution.normalize(body, [{"x-client-request-id", "request"}])
    opts = CodexAttribution.options(body, "key")
    assert opts[:session_id] == opts[:prompt_cache_key]
    refute Keyword.has_key?(opts, :codex_turn_metadata)
    assert CodexAttribution.options(%{}, "key") == []
    assert {:ok, %{}} = CodexAttribution.normalize(%{}, [{"originator", "some-client"}])
  end
end
