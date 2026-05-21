defmodule EngramWeb.LogsControllerTest do
  use EngramWeb.ConnCase, async: true

  setup %{conn: conn} do
    user = insert(:user)
    _vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user}
  end

  # ---------------------------------------------------------------------------
  # POST /logs — Ingest
  # ---------------------------------------------------------------------------

  describe "POST /logs" do
    test "ingests a batch of log entries", %{conn: conn} do
      conn =
        post(conn, "/api/logs", %{
          logs: [
            %{
              ts: "2026-04-03T01:00:00Z",
              level: "info",
              category: "sync",
              message: "Push completed",
              plugin_version: "0.6.0",
              platform: "desktop"
            },
            %{
              ts: "2026-04-03T01:00:01Z",
              level: "error",
              category: "sync",
              message: "Pull failed",
              stack: "Error at line 42",
              plugin_version: "0.6.0",
              platform: "desktop"
            }
          ]
        })

      assert %{"ok" => true, "count" => 2} = json_response(conn, 200)
    end

    test "accepts empty logs array", %{conn: conn} do
      conn = post(conn, "/api/logs", %{logs: []})
      assert %{"ok" => true, "count" => 0} = json_response(conn, 200)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post("/api/logs", %{logs: []})

      assert json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /logs — Query
  # ---------------------------------------------------------------------------

  describe "GET /logs" do
    setup %{conn: conn} do
      # Seed some logs
      post(conn, "/api/logs", %{
        logs: [
          %{
            ts: "2026-04-03T01:00:00Z",
            level: "info",
            category: "sync",
            message: "msg1",
            platform: "desktop"
          },
          %{
            ts: "2026-04-03T01:01:00Z",
            level: "error",
            category: "sync",
            message: "msg2",
            platform: "desktop"
          },
          %{
            ts: "2026-04-03T01:02:00Z",
            level: "info",
            category: "search",
            message: "msg3",
            platform: "mobile"
          }
        ]
      })

      :ok
    end

    test "returns all logs for user", %{conn: conn} do
      conn = get(conn, "/api/logs")
      body = json_response(conn, 200)

      assert is_list(body["logs"])
      assert length(body["logs"]) == 3
    end

    test "filters by level", %{conn: conn} do
      conn = get(conn, "/api/logs", %{level: "error"})
      body = json_response(conn, 200)

      assert length(body["logs"]) == 1
      assert hd(body["logs"])["level"] == "error"
    end

    test "filters by category", %{conn: conn} do
      conn = get(conn, "/api/logs", %{category: "search"})
      body = json_response(conn, 200)

      assert length(body["logs"]) == 1
      assert hd(body["logs"])["category"] == "search"
    end

    test "filters by since timestamp", %{conn: conn} do
      conn = get(conn, "/api/logs", %{since: "2026-04-03T01:01:30Z"})
      body = json_response(conn, 200)

      assert length(body["logs"]) == 1
      assert hd(body["logs"])["message"] == "msg3"
    end

    test "returns newest first", %{conn: conn} do
      conn = get(conn, "/api/logs")
      body = json_response(conn, 200)

      messages = Enum.map(body["logs"], & &1["message"])
      assert messages == ["msg3", "msg2", "msg1"]
    end

    test "respects limit parameter", %{conn: conn} do
      conn = get(conn, "/api/logs", %{limit: "1"})
      body = json_response(conn, 200)

      assert length(body["logs"]) == 1
    end

    test "log entries have expected fields", %{conn: conn} do
      conn = get(conn, "/api/logs")
      body = json_response(conn, 200)

      entry = hd(body["logs"])
      assert Map.has_key?(entry, "id")
      assert Map.has_key?(entry, "ts")
      assert Map.has_key?(entry, "level")
      assert Map.has_key?(entry, "category")
      assert Map.has_key?(entry, "message")
      assert Map.has_key?(entry, "platform")
    end

    test "multi-tenant isolation — user B cannot see user A's logs", %{conn: _conn} do
      user_b = insert(:user)
      insert(:vault, user: user_b, is_default: true)
      {:ok, api_key_b, _} = Engram.Accounts.create_api_key(user_b, "b-key")
      grant_api_write!(user_b)

      conn_b =
        build_conn()
        |> put_req_header("authorization", "Bearer #{api_key_b}")

      conn_b = get(conn_b, "/api/logs")
      body = json_response(conn_b, 200)

      assert body["logs"] == []
    end
  end
end
