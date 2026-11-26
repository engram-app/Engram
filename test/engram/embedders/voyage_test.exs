defmodule Engram.Embedders.VoyageTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Engram.Embedders.Voyage
  alias Engram.ServiceConfig

  setup do
    bypass = Bypass.open()
    # Per-process overrides (not global put_env) so this suite runs async.
    ServiceConfig.put_override(:voyage_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:voyage_api_key, "test-key")

    %{bypass: bypass}
  end

  describe "embed_texts/1" do
    test "returns vectors on success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        body = %{
          "data" => [
            %{"embedding" => [0.1, 0.2, 0.3]},
            %{"embedding" => [0.4, 0.5, 0.6]}
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      assert {:ok, vectors} = Voyage.embed_texts(["hello", "world"])
      assert length(vectors) == 2
      assert hd(vectors) == [0.1, 0.2, 0.3]
    end

    test "prefers a ServiceConfig per-process override over global app env" do
      # `setup` points the global :voyage_url at `bypass`. Install a per-process
      # override at a *different* Bypass and assert the request follows the
      # override — proving the read goes through ServiceConfig, the seam that
      # lets this suite run async without racing the global key.
      override_bypass = Bypass.open()
      Engram.ServiceConfig.put_override(:voyage_url, "http://localhost:#{override_bypass.port}")

      Bypass.expect_once(override_bypass, "POST", "/v1/embeddings", fn conn ->
        body = %{"data" => [%{"embedding" => [0.7]}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      assert {:ok, [[0.7]]} = Voyage.embed_texts(["only-via-override"])
    end

    test "returns error on non-200 response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        Plug.Conn.send_resp(conn, 400, ~s({"error": "invalid input"}))
      end)

      assert {:error, _} = Voyage.embed_texts(["hello"])
    end

    test "returns error on network failure", %{bypass: bypass} do
      Bypass.down(bypass)

      capture_log(fn ->
        # Pass retry: false to avoid 3 retries with backoff against a dead server
        assert {:error, _} = Voyage.embed_texts(["hello"], retry: false)
      end)
    end

    test "query purpose defaults to fast-fail request options" do
      # Interactive search holds a request process for the full embed call.
      # With the index defaults (30s timeout x 4 attempts) a Voyage brownout
      # pins searches for up to ~2 minutes each. Queries fail fast instead;
      # callers can still override per call.
      defaults = Voyage.request_defaults(:query)
      assert defaults[:receive_timeout] == 5_000
      assert defaults[:retry] == (&Voyage.retry_query?/2)
      assert defaults[:max_retries] == 1
    end

    # A pooled keep-alive socket the far side closed while idle fails the next
    # request instantly with `:closed` (prod: every failed query embed in a
    # week, each degrading search to keyword-only). One immediate retry on a
    # fresh connection recovers it.
    test "query purpose retries a closed connection once, immediately" do
      port = flaky_http_server(close_first: 1)
      ServiceConfig.put_override(:voyage_url, "http://localhost:#{port}")

      capture_log(fn ->
        assert {:ok, [[0.1]]} = Voyage.embed_texts(["hello"], purpose: :query)
      end)

      assert_receive {:flaky_http_server, :served, 2}
    end

    test "query purpose gives up after one retry of a closed connection" do
      port = flaky_http_server(close_first: 2)
      ServiceConfig.put_override(:voyage_url, "http://localhost:#{port}")

      capture_log(fn ->
        assert {:error, %Req.TransportError{reason: :closed}} =
                 Voyage.embed_texts(["hello"], purpose: :query)
      end)
    end

    # A timeout may have reached the model and still be running; retrying it
    # would double the wait on a user-blocking path.
    test "query purpose does not retry a timeout", %{bypass: bypass} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.stub(bypass, "POST", "/v1/embeddings", fn conn ->
        Agent.update(counter, &(&1 + 1))
        Process.sleep(300)
        Plug.Conn.send_resp(conn, 200, ~s({"data":[{"embedding":[0.1]}]}))
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Voyage.embed_texts(["x"], purpose: :query, receive_timeout: 50)

      Process.sleep(350)
      assert Agent.get(counter, & &1) == 1
      Bypass.pass(bypass)
    end

    test "retry_query? retries only failures that never got a response" do
      req = Req.new()
      assert Voyage.retry_query?(req, %Req.TransportError{reason: :closed}) == {:delay, 0}
      assert Voyage.retry_query?(req, %Req.TransportError{reason: :econnrefused}) == {:delay, 0}
      refute Voyage.retry_query?(req, %Req.TransportError{reason: :timeout})
      refute Voyage.retry_query?(req, %Req.Response{status: 429})
      refute Voyage.retry_query?(req, %Req.Response{status: 500})
    end

    test "index purpose keeps patient retry defaults" do
      defaults = Voyage.request_defaults(:index)
      assert defaults[:receive_timeout] == 30_000
      assert defaults[:retry] == :transient
      assert defaults[:max_retries] == 3
    end

    test "query purpose does not retry against a failing upstream", %{bypass: bypass} do
      # Behavior pin: with purpose: :query and no caller overrides, a 500
      # gets exactly ONE request (5xx is never retried), not 4.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
        Agent.update(counter, &(&1 + 1))
        Plug.Conn.send_resp(conn, 500, ~s({"error": "boom"}))
      end)

      capture_log(fn ->
        assert {:error, {500, _}} = Voyage.embed_texts(["hello"], purpose: :query)
      end)

      assert Agent.get(counter, & &1) == 1
    end

    test "sends correct model in request body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == Application.get_env(:engram, :embed_model, "voyage-4-large")
        assert decoded["input"] == ["hello"]

        resp = %{"data" => [%{"embedding" => [0.1]}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      Voyage.embed_texts(["hello"])
    end

    # #1614: Voyage prepends its retrieval prompts only when told whether an
    # input is a query or a document, and without output_dimension a
    # non-default EMBED_DIMS disagrees with the vectors Voyage returns.
    test "indexing sends input_type document and the configured output_dimension",
         %{bypass: bypass} do
      expect_body(bypass)
      ServiceConfig.put_override(:embed_dims, 512)

      assert {:ok, _} = Voyage.embed_texts(["hello"])
      assert_receive {:body, %{"input_type" => "document", "output_dimension" => 512}}
    end

    # Indexing asks for packed float32 (base64): ~3x smaller responses and no
    # JSON float parsing; Indexing holds vectors packed anyway. Search keeps
    # float lists, which go straight into the Qdrant query.
    test "indexing requests base64 vectors; search does not", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"data":[{"embedding":[0.1]}]}))
      end)

      assert {:ok, _} = Voyage.embed_texts(["hello"])
      assert_receive {:body, %{"encoding_format" => "base64"}}

      assert {:ok, _} = Voyage.embed_texts(["hello"], purpose: :query)
      assert_receive {:body, query_body}
      refute Map.has_key?(query_body, "encoding_format")
    end

    test "base64 vectors come back as packed float32 binaries", %{bypass: bypass} do
      packed = <<0.5::float-32-little, -1.0::float-32-little, 0.25::float-32-little>>

      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"embedding" => Base.encode64(packed)}]})
        )
      end)

      assert {:ok, [^packed]} = Voyage.embed_texts(["hello"])
    end

    test "a malformed base64 vector raises and the span reports it", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => [%{"embedding" => "not base64!"}]}))
      end)

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:engram, :voyage, :embed, :exception]])

      assert_raise ArgumentError, ~r/11 bytes/, fn -> Voyage.embed_texts(["hello"]) end
      assert_received {[:engram, :voyage, :embed, :exception], ^ref, _, %{kind: :error}}
    end

    test "search sends input_type query", %{bypass: bypass} do
      expect_body(bypass)

      assert {:ok, _} = Voyage.embed_texts(["hello"], purpose: :query)
      assert_receive {:body, %{"input_type" => "query"}}
    end

    # Older Voyage models (voyage-2, voyage-law-2, ...) reject output_dimension
    # outright, and EMBED_DIMS has no default in config, so sending 1024
    # unasked would 400 every embed for a self-hoster on one of them. Only an
    # operator who set EMBED_DIMS gets the field.
    test "omits output_dimension when EMBED_DIMS is not configured", %{bypass: bypass} do
      expect_body(bypass)

      assert {:ok, _} = Voyage.embed_texts(["hello"])
      assert_receive {:body, body}
      refute Map.has_key?(body, "output_dimension")
    end
  end

  describe "truncation: false (over-length input fails loudly)" do
    # Voyage defaults `truncation` to true and silently embeds a prefix of an
    # over-length input. Sent false, the same input is a 400 instead.
    test "indexing and search both send truncation false", %{bypass: bypass} do
      expect_body(bypass)
      assert {:ok, _} = Voyage.embed_texts(["hello"])
      assert_receive {:body, %{"truncation" => false}}

      expect_body(bypass)
      assert {:ok, _} = Voyage.embed_texts(["hello"], purpose: :query)
      assert_receive {:body, %{"truncation" => false}}
    end

    test "a context-window 400 is permanent, after exactly one request", %{bypass: bypass} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
        Agent.update(counter, &(&1 + 1))

        Plug.Conn.send_resp(
          conn,
          400,
          ~s({"detail":"Request to model 'voyage-4-large' failed. The input at index 0 does not fit into the model's context window of 32000 tokens."})
        )
      end)

      assert {:error, {:permanent, :input_too_long}} = Voyage.embed_texts(["huge"])
      assert Agent.get(counter, & &1) == 1
    end

    test "any other 400 keeps the raw status and body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"detail":"invalid model"}))
      end)

      assert {:error, {400, %{"detail" => "invalid model"}}} = Voyage.embed_texts(["x"])
    end
  end

  describe "maintenance purpose" do
    test "defaults never retry a receive timeout" do
      assert Voyage.request_defaults(:maintenance) == [
               receive_timeout: 30_000,
               retry: &Voyage.retry_maintenance?/2
             ]

      req = Req.new()
      refute Voyage.retry_maintenance?(req, %Req.TransportError{reason: :timeout})
      refute Voyage.retry_maintenance?(req, %Req.Response{status: 500})
      refute Voyage.retry_maintenance?(req, %Req.Response{status: 400})
      assert Voyage.retry_maintenance?(req, %Req.Response{status: 429})
      assert Voyage.retry_maintenance?(req, %Req.TransportError{reason: :econnrefused})
    end

    # H6: a timed-out request may still have been billed; a retry pays again.
    test "a maintenance request that times out makes exactly one call", %{bypass: bypass} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.stub(bypass, "POST", "/v1/embeddings", fn conn ->
        Agent.update(counter, &(&1 + 1))
        Process.sleep(300)
        Plug.Conn.send_resp(conn, 200, ~s({"data":[{"embedding":[0.1]}]}))
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Voyage.embed_texts(["x"], purpose: :maintenance, receive_timeout: 50)

      Process.sleep(350)
      assert Agent.get(counter, & &1) == 1
      # The client hung up on the sleeping handler; that is the point.
      Bypass.pass(bypass)
    end
  end

  # Raw HTTP/1.1 server: the first `close_first` connections read the request
  # and close without a response (what a stale pooled socket looks like to
  # Mint: `:closed`); later ones answer 200. Reports each served connection.
  defp flaky_http_server(close_first: n) do
    test_pid = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    pid = spawn_link(fn -> serve_flaky(listen, test_pid, n, 1) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    on_exit(fn -> :gen_tcp.close(listen) end)
    port
  end

  defp serve_flaky(listen, test_pid, n, i) do
    with {:ok, sock} <- :gen_tcp.accept(listen),
         {:ok, _request} <- :gen_tcp.recv(sock, 0, 1_000) do
      if i > n do
        body = ~s({"data":[{"embedding":[0.1]}]})

        :gen_tcp.send(
          sock,
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
            "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
        )
      end

      :gen_tcp.close(sock)
      send(test_pid, {:flaky_http_server, :served, i})
      serve_flaky(listen, test_pid, n, i + 1)
    end
  end

  defp expect_body(bypass) do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"data":[{"embedding":[0.1]}]}))
    end)
  end

  describe "client-side rate limit (VOYAGE_RPM)" do
    setup do
      # Per-test bucket key prevents cross-pollination between async tests
      # sharing the EngramWeb.RateLimiter ETS table.
      key = "voyage_embed_test_#{:erlang.unique_integer([:positive])}"
      ServiceConfig.put_override(:voyage_throttle_key, key)
      :ok
    end

    test "no throttle when VOYAGE_RPM is unset (default)", %{bypass: bypass} do
      refute Application.get_env(:engram, :voyage_rpm)

      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        resp = %{"data" => [%{"embedding" => [0.1]}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      assert {:ok, _} = Voyage.embed_texts(["hello"])
    end

    test "returns synthetic 429 once bucket is exhausted, without hitting HTTP", %{bypass: bypass} do
      ServiceConfig.put_override(:voyage_rpm, 1)

      Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
        resp = %{"data" => [%{"embedding" => [0.1]}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      # First call consumes the only token.
      assert {:ok, _} = Voyage.embed_texts(["hello"])

      # Second call must NOT hit Bypass — synthetic 429 instead.
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:engram, :embed, :client_rate_limited],
        fn _name, _measurements, metadata, _ -> send(test_pid, {:throttled, ref, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      assert {:error, {429, body}} = Voyage.embed_texts(["world"], model: "voyage-4-lite")
      assert body["detail"] == "client_rate_limited"
      assert is_integer(body["retry_after_ms"])
      assert_receive {:throttled, ^ref, %{model: "voyage-4-lite"}}
    end

    test "allows calls when bucket has tokens", %{bypass: bypass} do
      ServiceConfig.put_override(:voyage_rpm, 10)

      Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
        resp = %{"data" => [%{"embedding" => [0.1]}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      assert {:ok, _} = Voyage.embed_texts(["a"])
      assert {:ok, _} = Voyage.embed_texts(["b"])
      assert {:ok, _} = Voyage.embed_texts(["c"])
    end
  end

  describe "token usage telemetry" do
    test "emits [:engram, :voyage, :embed, :tokens] when response includes usage", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        body = %{
          "data" => [%{"embedding" => [0.1, 0.2]}],
          "model" => "voyage-4-large",
          "usage" => %{"total_tokens" => 42}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      handler_id = {__MODULE__, :tokens_handler, System.unique_integer()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:engram, :voyage, :embed, :tokens],
        fn _event, measurements, meta, _ ->
          send(test_pid, {:voyage_tokens, measurements, meta})
        end,
        nil
      )

      try do
        assert {:ok, _vectors} = Voyage.embed_texts(["hello"], purpose: :query)

        assert_received {:voyage_tokens, %{total_tokens: 42}, %{purpose: :query}}
      after
        :telemetry.detach(handler_id)
      end
    end

    test "labels tokens with the pass's tier and trigger, and emits tokens per chunk", %{
      bypass: bypass
    } do
      Bypass.expect(bypass, "POST", "/v1/embeddings", fn conn ->
        body = %{
          "data" => [%{"embedding" => [0.1]}, %{"embedding" => [0.2]}],
          "usage" => %{"total_tokens" => 90}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      handler_id = {__MODULE__, :labels_handler, System.unique_integer()}
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [[:engram, :voyage, :embed, :tokens], [:engram, :voyage, :embed, :tokens_per_chunk]],
        fn event, m, meta, _ -> send(test_pid, {:ev, List.last(event), m, meta}) end,
        nil
      )

      try do
        Engram.Embedders.UsageLabels.with_labels(:free, :rebuild, fn ->
          assert {:ok, _} = Voyage.embed_texts(["a", "b"])
        end)

        assert_received {:ev, :tokens, %{total_tokens: 90}, %{tier: :free, trigger: :rebuild}}
        assert_received {:ev, :tokens_per_chunk, %{tokens: 45}, %{tier: :free}}

        # Outside a pass (a search query) both read :none.
        assert {:ok, _} = Voyage.embed_texts(["a", "b"], purpose: :query)
        assert_received {:ev, :tokens, _, %{tier: :none, trigger: :none}}
      after
        :telemetry.detach(handler_id)
      end
    end

    test "defaults purpose tag to :index when caller omits opts", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        body = %{
          "data" => [%{"embedding" => [0.1]}],
          "usage" => %{"total_tokens" => 7}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      handler_id = {__MODULE__, :tokens_default_handler, System.unique_integer()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:engram, :voyage, :embed, :tokens],
        fn _event, measurements, meta, _ ->
          send(test_pid, {:voyage_tokens, measurements, meta})
        end,
        nil
      )

      try do
        assert {:ok, _} = Voyage.embed_texts(["hello"])
        assert_received {:voyage_tokens, %{total_tokens: 7}, %{purpose: :index}}
      after
        :telemetry.detach(handler_id)
      end
    end

    test "does NOT emit tokens event when response omits usage field", %{bypass: bypass} do
      # Defensive: Voyage's documented embedding response always includes
      # usage, but we should not crash or emit a 0-token event if a future
      # endpoint shape drops it. Absence-of-event is the contract.
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        body = %{"data" => [%{"embedding" => [0.1]}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      handler_id = {__MODULE__, :tokens_absent_handler, System.unique_integer()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:engram, :voyage, :embed, :tokens],
        fn _event, measurements, meta, _ ->
          send(test_pid, {:voyage_tokens, measurements, meta})
        end,
        nil
      )

      try do
        assert {:ok, _} = Voyage.embed_texts(["hello"])
        refute_received {:voyage_tokens, _, _}
      after
        :telemetry.detach(handler_id)
      end
    end

    test "does NOT emit tokens event on non-200 response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        Plug.Conn.send_resp(conn, 500, ~s({"error": "server"}))
      end)

      handler_id = {__MODULE__, :tokens_error_handler, System.unique_integer()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:engram, :voyage, :embed, :tokens],
        fn _event, measurements, meta, _ ->
          send(test_pid, {:voyage_tokens, measurements, meta})
        end,
        nil
      )

      try do
        assert {:error, _} = Voyage.embed_texts(["hello"], retry: false)
        refute_received {:voyage_tokens, _, _}
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "embed_texts/2" do
    test "uses model override when provided", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "voyage-4-lite"

        resp = %{"data" => [%{"embedding" => [0.1, 0.2]}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      assert {:ok, _} = Voyage.embed_texts(["hello"], model: "voyage-4-lite")
    end

    test "falls back to configured model when no override", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == Application.get_env(:engram, :embed_model, "voyage-4-large")

        resp = %{"data" => [%{"embedding" => [0.1, 0.2]}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      assert {:ok, _} = Voyage.embed_texts(["hello"], [])
    end
  end
end
