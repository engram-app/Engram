defmodule EngramWeb.Plugs.EnforceConnectionCapTest do
  use EngramWeb.ConnCase, async: false

  alias EngramWeb.Plugs.EnforceConnectionCap

  describe "EnforceConnectionCap" do
    setup %{conn: conn} do
      user = insert(:user)
      obs_client = insert(:oauth_client, kind: "obsidian")
      mcp_client = insert(:oauth_client, kind: "mcp")
      {:ok, conn: conn, user: user, obs: obs_client, mcp: mcp_client}
    end

    test "passes when below cap (Free user, no existing connections)", %{
      conn: conn,
      user: user,
      obs: client
    } do
      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/oauth/authorize/consent")
        |> Map.put(:params, %{"client_id" => client.client_id})
        |> assign(:current_user, user)
        |> EnforceConnectionCap.call([])

      refute conn.halted
    end

    test "halts 402 at cap with full body (Free user, 1 existing obsidian connection)", %{
      conn: conn,
      user: user,
      obs: client
    } do
      insert(:oauth_refresh_token, user_id: user.id, client_id: client.client_id)

      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/oauth/authorize/consent")
        |> Map.put(:params, %{"client_id" => client.client_id})
        |> assign(:current_user, user)
        |> EnforceConnectionCap.call([])

      assert conn.halted
      assert conn.status == 402
      body = Phoenix.ConnTest.json_response(conn, 402)
      assert body["error"] == "limit_exceeded"
      assert body["reason"] == "obsidian_connections_exceeded"
      assert body["limit_key"] == "obsidian_connections_cap"
      assert body["current"] == 1
      assert body["limit"] == 1
      assert body["upgrade_url"] == "https://app.engram.page/settings/billing"
      assert body["tier"] == "free"
    end

    test "obsidian cap does not affect mcp consent", %{conn: conn, user: user, obs: obs, mcp: mcp} do
      # 1 obsidian connection exists (at obsidian cap of 1)
      insert(:oauth_refresh_token, user_id: user.id, client_id: obs.client_id)

      # But mcp consent for a different kind should still pass — mcp count is 0
      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/oauth/authorize/consent")
        |> Map.put(:params, %{"client_id" => mcp.client_id})
        |> assign(:current_user, user)
        |> EnforceConnectionCap.call([])

      refute conn.halted
    end

    test "returns 400 when client_id is missing", %{conn: conn, user: user} do
      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/oauth/authorize/consent")
        |> Map.put(:params, %{})
        |> assign(:current_user, user)
        |> EnforceConnectionCap.call([])

      assert conn.halted
      assert conn.status == 400
      body = Phoenix.ConnTest.json_response(conn, 400)
      assert body["error"] == "missing_or_invalid_client_id"
    end

    test "returns 400 when client_id is unknown", %{conn: conn, user: user} do
      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/oauth/authorize/consent")
        |> Map.put(:params, %{"client_id" => Ecto.UUID.generate()})
        |> assign(:current_user, user)
        |> EnforceConnectionCap.call([])

      assert conn.halted
      assert conn.status == 400
    end

    test "passes when limits_enforced is false (self-host / unlimited tier)", %{
      conn: conn,
      user: user,
      mcp: client
    } do
      # Disable enforcement — simulates self-host bypass or unlimited tier.
      # effective_limit/2 returns :unlimited when enforced? is false.
      prev = Application.get_env(:engram, :limits_enforced)
      Application.put_env(:engram, :limits_enforced, false)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:engram, :limits_enforced),
          else: Application.put_env(:engram, :limits_enforced, prev)
      end)

      # Even with an existing connection, :unlimited bypass passes
      insert(:oauth_refresh_token, user_id: user.id, client_id: client.client_id)

      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/oauth/authorize/consent")
        |> Map.put(:params, %{"client_id" => client.client_id})
        |> assign(:current_user, user)
        |> EnforceConnectionCap.call([])

      refute conn.halted
    end

    test "passes when override sets cap to -1 (unlimited sentinel)", %{
      conn: conn,
      user: user,
      mcp: client
    } do
      # -1 is the canonical unlimited sentinel; cap_json/-1 → nil on the
      # wire, and the plug must treat it the same as :unlimited / nil.
      insert(:user_limit_override,
        user: user,
        key: "mcp_connections_cap",
        value: %{"v" => -1}
      )

      # Existing connection: even with one live grant, -1 still passes.
      insert(:oauth_refresh_token, user_id: user.id, client_id: client.client_id)

      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/oauth/authorize/consent")
        |> Map.put(:params, %{"client_id" => client.client_id})
        |> assign(:current_user, user)
        |> EnforceConnectionCap.call([])

      refute conn.halted
    end

    test "raises if :current_user is not assigned (programmer error guard)", %{conn: conn} do
      assert_raise RuntimeError, ~r/requires :current_user/, fn ->
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/oauth/authorize/consent")
        |> Map.put(:params, %{})
        |> EnforceConnectionCap.call([])
      end
    end

    test "passes when oauth_clients.kind is an unexpected value (fails open + logs)", %{
      conn: conn,
      user: user
    } do
      import ExUnit.CaptureLog

      drift_client_id = Ecto.UUID.generate()

      # The oauth_clients table has a CHECK constraint (kind IN ('mcp', 'obsidian')).
      # Drop it inside the ConnCase transaction so we can insert a "desktop" kind row
      # that simulates DB drift. Postgres DDL is transactional: the DROP is rolled back
      # at the end of the test along with the row, leaving the real schema intact.
      Engram.Repo.query!(
        "ALTER TABLE oauth_clients DROP CONSTRAINT IF EXISTS oauth_clients_kind_check",
        [],
        skip_tenant_check: true
      )

      Engram.Repo.insert_all(
        "oauth_clients",
        [
          %{
            client_id: Ecto.UUID.dump!(drift_client_id),
            redirect_uris: ["http://127.0.0.1/cb"],
            client_name: "Drift Kind Client",
            kind: "desktop",
            grant_types: ["authorization_code", "refresh_token"],
            response_types: ["code"],
            token_endpoint_auth_method: "none",
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        ],
        skip_tenant_check: true
      )

      log =
        capture_log(fn ->
          result_conn =
            conn
            |> Map.put(:method, "POST")
            |> Map.put(:request_path, "/api/oauth/authorize/consent")
            |> Map.put(:params, %{"client_id" => drift_client_id})
            |> assign(:current_user, user)
            |> EnforceConnectionCap.call([])

          refute result_conn.halted
        end)

      assert log =~ "unknown oauth_clients.kind"
    end
  end
end
