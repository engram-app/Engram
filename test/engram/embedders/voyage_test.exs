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
      assert defaults[:retry] == false
    end

    test "index purpose keeps patient retry defaults" do
      defaults = Voyage.request_defaults(:index)
      assert defaults[:receive_timeout] == 30_000
      assert defaults[:retry] == :transient
      assert defaults[:max_retries] == 3
    end

    test "query purpose does not retry against a failing upstream", %{bypass: bypass} do
      # Behavior pin: with purpose: :query and no caller overrides, a 500
      # gets exactly ONE request (retry: false), not 4.
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
      assert {:error, {429, body}} = Voyage.embed_texts(["world"])
      assert body["detail"] == "client_rate_limited"
      assert is_integer(body["retry_after_ms"])
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
