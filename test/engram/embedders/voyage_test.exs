defmodule Engram.Embedders.VoyageTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Engram.Embedders.Voyage

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :voyage_url, "http://localhost:#{bypass.port}")
    Application.put_env(:engram, :voyage_api_key, "test-key")

    on_exit(fn ->
      Application.delete_env(:engram, :voyage_url)
      Application.delete_env(:engram, :voyage_api_key)
    end)

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
      Application.put_env(:engram, :voyage_throttle_key, key)
      on_exit(fn -> Application.delete_env(:engram, :voyage_throttle_key) end)
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
      Application.put_env(:engram, :voyage_rpm, 1)
      on_exit(fn -> Application.delete_env(:engram, :voyage_rpm) end)

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
      Application.put_env(:engram, :voyage_rpm, 10)
      on_exit(fn -> Application.delete_env(:engram, :voyage_rpm) end)

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
