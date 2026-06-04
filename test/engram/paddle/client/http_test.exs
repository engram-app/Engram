defmodule Engram.Paddle.Client.HTTPTest do
  use ExUnit.Case, async: false

  alias Engram.Paddle.Client.HTTP

  @since ~U[2026-01-01 00:00:00Z]

  setup do
    bypass = Bypass.open()

    Application.put_env(:engram, :paddle_api_key, "test-key")
    Application.put_env(:engram, :paddle_api_base_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      Application.delete_env(:engram, :paddle_api_key)
      Application.delete_env(:engram, :paddle_api_base_url)
    end)

    %{bypass: bypass}
  end

  describe "list_subscriptions/1 pagination" do
    test "returns single-page flattened list when no next", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/subscriptions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "data" => [%{"id" => "sub_1"}],
            "meta" => %{"pagination" => %{"next" => nil}}
          })
        )
      end)

      assert {:ok, [%{"id" => "sub_1"}]} = HTTP.list_subscriptions(@since)
    end

    test "follows meta.pagination.next URL with empty params on follow-up", %{bypass: bypass} do
      next_url = "http://localhost:#{bypass.port}/subscriptions?after=sub_1"

      Bypass.expect(bypass, "GET", "/subscriptions", fn conn ->
        body =
          case conn.query_string do
            "after=sub_1" ->
              %{"data" => [%{"id" => "sub_2"}], "meta" => %{"pagination" => %{"next" => nil}}}

            _ ->
              %{
                "data" => [%{"id" => "sub_1"}],
                "meta" => %{"pagination" => %{"next" => next_url}}
              }
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      assert {:ok, [%{"id" => "sub_1"}, %{"id" => "sub_2"}]} = HTTP.list_subscriptions(@since)
    end

    test "treats empty-string next as terminator", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/subscriptions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "data" => [%{"id" => "sub_1"}],
            "meta" => %{"pagination" => %{"next" => ""}}
          })
        )
      end)

      assert {:ok, [%{"id" => "sub_1"}]} = HTTP.list_subscriptions(@since)
    end

    test "returns :partial with :pagination_loop tag when same next URL is returned twice",
         %{bypass: bypass} do
      # Paddle returns the same next URL every time → would otherwise
      # infinite-recurse. The seen-URL guard must stop, return :partial
      # tagged with :pagination_loop, and surface what we've collected.
      loop_url = "http://localhost:#{bypass.port}/subscriptions?cursor=loop"

      Bypass.expect(bypass, "GET", "/subscriptions", fn conn ->
        body = %{
          "data" => [%{"id" => "sub_loop_" <> (conn.query_string || "first")}],
          "meta" => %{"pagination" => %{"next" => loop_url}}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      assert {:partial, results, :pagination_loop} = HTTP.list_subscriptions(@since)
      assert results != []
      # And critically — it terminates.
    end

    test "returns :partial with :max_pages_exceeded when Paddle keeps returning fresh next URLs",
         %{bypass: bypass} do
      # Bypass always returns a fresh next URL with the page number — the
      # seen-URL guard never trips. The @max_pages 50 cap MUST stop it
      # so the daily Oban worker can't be DoS'd by Paddle misbehavior.
      base = "http://localhost:#{bypass.port}"
      counter = :counters.new(1, [])

      Bypass.expect(bypass, "GET", "/subscriptions", fn conn ->
        n = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        body = %{
          "data" => [%{"id" => "sub_p#{n}"}],
          "meta" => %{"pagination" => %{"next" => "#{base}/subscriptions?cursor=p#{n}"}}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      assert {:partial, results, :max_pages_exceeded} = HTTP.list_subscriptions(@since)
      # Cap is @max_pages 50 — should hit it and stop.
      assert length(results) >= 50
    end

    test "returns {:error, {:paddle_error, status}} on non-200", %{bypass: bypass} do
      # Req's default retry policy retries 5xx up to 4 attempts. Use a
      # 400 (non-retried) so the test doesn't spend 7s in backoff.
      Bypass.expect_once(bypass, "GET", "/subscriptions", fn conn ->
        Plug.Conn.send_resp(conn, 400, ~s({"error": "bad request"}))
      end)

      assert {:error, {:paddle_error, 400}} = HTTP.list_subscriptions(@since)
    end

    test "sends updated_at[GTE] filter and per_page=200 on first request", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/subscriptions", fn conn ->
        assert conn.query_string =~ "updated_at"
        assert conn.query_string =~ "per_page=200"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => [], "meta" => %{}}))
      end)

      assert {:ok, []} = HTTP.list_subscriptions(@since)
    end
  end
end
