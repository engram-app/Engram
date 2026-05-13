defmodule Engram.Rerankers.JinaTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :jina_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :jina_url) end)
    %{bypass: bypass}
  end

  describe "rerank/3" do
    test "returns reranked results with blended scores", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/rerank", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["query"] == "iron supplements"
        assert length(decoded["documents"]) == 2

        resp = %{
          "results" => [
            %{"index" => 1, "relevance_score" => 0.95},
            %{"index" => 0, "relevance_score" => 0.60}
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      candidates = [
        %{score: 0.9, text: "Ferritin is an iron storage protein"},
        %{score: 0.8, text: "Iron supplements help with anemia"}
      ]

      assert {:ok, results} = Jina.rerank("iron supplements", candidates, 2)
      assert length(results) == 2

      # Second candidate should rank first (higher reranker score)
      first = hd(results)
      assert first.text == "Iron supplements help with anemia"
    end

    test "returns fallback on Jina error", %{bypass: bypass} do
      Bypass.down(bypass)

      candidates = [
        %{score: 0.9, text: "Result A"},
        %{score: 0.7, text: "Result B"}
      ]

      capture_log(fn ->
        assert {:ok, results} = Jina.rerank("query", candidates, 2)
        # Falls back to vector scores — Result A first
        assert hd(results).text == "Result A"
      end)
    end

    test "returns fallback when Jina returns non-200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/rerank", fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      candidates = [%{score: 0.8, text: "Only result"}]

      capture_log(fn ->
        assert {:ok, [result]} = Jina.rerank("query", candidates, 1)
        assert result.text == "Only result"
      end)
    end

    test "handles empty candidates", %{bypass: _bypass} do
      assert {:ok, []} = Jina.rerank("query", [], 5)
    end

    test "respects top_n limit", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/rerank", fn conn ->
        resp = %{
          "results" => [
            %{"index" => 0, "relevance_score" => 0.9},
            %{"index" => 1, "relevance_score" => 0.8},
            %{"index" => 2, "relevance_score" => 0.7}
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      candidates = [
        %{score: 0.5, text: "A"},
        %{score: 0.4, text: "B"},
        %{score: 0.3, text: "C"}
      ]

      assert {:ok, results} = Jina.rerank("query", candidates, 2)
      assert length(results) == 2
    end
  end
end
