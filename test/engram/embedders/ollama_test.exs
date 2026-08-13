defmodule Engram.Embedders.OllamaTest do
  use ExUnit.Case, async: true

  alias Engram.Embedders.Ollama

  # Stub the HTTP layer via Req's `plug:` adapter (routed through embed_texts
  # opts) so these run async with no network and no OLLAMA_URL env mutation.
  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  describe "embed_texts/2" do
    test "returns vectors on success" do
      plug = fn conn -> json_resp(conn, 200, %{"embeddings" => [[0.1, 0.2], [0.3, 0.4]]}) end
      assert {:ok, [[0.1, 0.2], [0.3, 0.4]]} = Ollama.embed_texts(["a", "b"], plug: plug)
    end

    test "retries a transient 5xx and succeeds (Oban embeds must survive a blip to remote Ollama)" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      plug = fn conn ->
        n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
        # First call: transient 503 (a FastRaid Ollama blip). Retry succeeds.
        if n == 1,
          do: json_resp(conn, 503, %{"error" => "loading"}),
          else: json_resp(conn, 200, %{"embeddings" => [[1.0, 2.0]]})
      end

      # retry_delay 0 keeps the test instant; retry: :transient is the fix.
      assert {:ok, [[1.0, 2.0]]} =
               Ollama.embed_texts(["hi"], plug: plug, retry_delay: fn _ -> 0 end)

      assert Agent.get(counter, & &1) == 2
    end

    test "gives up after max_retries on a persistent failure" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      plug = fn conn ->
        Agent.update(counter, &(&1 + 1))
        json_resp(conn, 503, %{"error" => "down"})
      end

      assert {:error, {503, _}} =
               Ollama.embed_texts(["hi"], plug: plug, retry_delay: fn _ -> 0 end)

      # 1 initial + 3 retries (max_retries: 3).
      assert Agent.get(counter, & &1) == 4
    end
  end

  describe "request_defaults/1 — query embeds must not inherit the indexing budget" do
    test "a query embed gets a bounded — but not tight — synchronous budget" do
      # A user (or MCP client) is BLOCKED on this call, so it must not inherit
      # the 120s index budget. But it must ALSO clear the measured contention:
      # Ollama serializes, so a query embed queues behind the embed worker's
      # 128-chunk index batches at ~4.3s each (~13.1s at depth 3, measured
      # 2026-08-12). A budget near that depth would time out under exactly the
      # load this exists to survive, silently dropping hybrid to keyword-only —
      # which makes a semantic-search test pass on the sparse leg.
      assert Ollama.request_defaults(:query)[:receive_timeout] == 45_000
    end

    test "the query budget clears the measured queueing depth with margin" do
      measured_depth_3_ms = 13_100
      assert Ollama.request_defaults(:query)[:receive_timeout] > measured_depth_3_ms * 2
    end

    test "an index embed keeps the long Oban budget" do
      # An Oban worker CAN afford to wait out a busy Ollama — nobody is blocked.
      assert Ollama.request_defaults(:index)[:receive_timeout] == 120_000
      assert Ollama.request_defaults(nil)[:receive_timeout] == 120_000
    end

    test "an UNKNOWN purpose falls back to the bounded budget, not the 120s hang" do
      # A typo (`purpose: :querry`) must not silently reinstate the two-minute
      # hang on a user-blocking path. Wrong-but-safe, and loud.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Ollama.request_defaults(:querry)[:receive_timeout] == 45_000
        end)

      assert log =~ "unknown purpose"
    end

    test "retries survive on BOTH purposes (unlike Voyage's retry: false)" do
      # Safe here only because retry_fast_transient?/2 refuses to retry a
      # receive_timeout — so retries cannot multiply either budget.
      for purpose <- [:query, :index] do
        assert Ollama.request_defaults(purpose)[:max_retries] == 3
        assert is_function(Ollama.request_defaults(purpose)[:retry], 2)
      end
    end
  end

  describe "embed_texts/2 purpose routing" do
    test "purpose never reaches Req as an unknown option" do
      # `purpose:` is our routing hint, not a Req option. If the split ever
      # stops dropping it, Req raises here rather than embedding.
      plug = fn conn -> json_resp(conn, 200, %{"embeddings" => [[1.0]]}) end
      assert {:ok, [[1.0]]} = Ollama.embed_texts(["hi"], purpose: :query, plug: plug)
      assert {:ok, [[1.0]]} = Ollama.embed_texts(["hi"], purpose: :index, plug: plug)
    end

    test "an explicit caller receive_timeout still wins over the purpose default" do
      # Mirrors Voyage: explicit caller opts always win. Asserted through the
      # real merge in embed_texts/2, not just the defaults table.
      plug = fn conn -> json_resp(conn, 200, %{"embeddings" => [[1.0]]}) end

      assert {:ok, [[1.0]]} =
               Ollama.embed_texts(["hi"], purpose: :query, receive_timeout: 42, plug: plug)
    end
  end

  describe "retry_fast_transient?/2" do
    test "retries fast failures but NOT a receive_timeout (no 120s amplification)" do
      # A hang-to-timeout must not be retried, else max_retries multiplies the
      # 120s receive_timeout into a multi-minute stall.
      refute Ollama.retry_fast_transient?(nil, %Req.TransportError{reason: :timeout})
      # Connection-level blips and 5xx fail fast → cheap to retry.
      assert Ollama.retry_fast_transient?(nil, %Req.TransportError{reason: :econnrefused})
      assert Ollama.retry_fast_transient?(nil, %Req.Response{status: 503})
      # 4xx / success are not transient.
      refute Ollama.retry_fast_transient?(nil, %Req.Response{status: 422})
      refute Ollama.retry_fast_transient?(nil, %Req.Response{status: 200})
    end
  end
end
