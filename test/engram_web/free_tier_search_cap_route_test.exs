defmodule EngramWeb.FreeTierSearchCapRouteTest do
  @moduledoc """
  Route-level proof that `ai_searches_per_day` refuses on every transport that
  can reach a retrieval.

  The charge lives in `Engram.Search.search/4` — the single funnel — rather than
  at each transport, so these tests exist to prove the funnel is REACHED from
  the real routes, not to re-test the arithmetic. The predecessor design charged
  per-transport against a hand-maintained list of retrieval tools, which is how
  the old cap went unenforced on all of MCP for months (#1527).

  Both transports share one key and one counter, so a bucket spent over REST is
  spent over MCP too. That is the whole point of collapsing six keys into one.
  """
  use EngramWeb.ConnCase, async: false

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "V", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "cap-test")
    grant_api_write!(user)

    # The budget is a Hammer bucket in ETS, which is process-global and NOT
    # reset by the DB sandbox. Each test mints a fresh user id, so keys never
    # collide, but reset anyway so a leaked bucket from another file cannot
    # make a refusal look like a pass.
    EngramWeb.RateLimiter.reset_buckets!()

    %{
      conn: put_req_header(conn, "authorization", "Bearer #{api_key}"),
      user: user,
      vault: vault
    }
  end

  defp cap!(user, n),
    do: insert(:user_limit_override, user: user, key: "ai_searches_per_day", value: %{"v" => n})

  defp rest_search(conn), do: post(conn, "/api/search", %{"query" => "anything"})

  defp mcp_search(conn) do
    post(conn, "/api/mcp", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "search_notes", "arguments" => %{"query" => "anything"}}
    })
  end

  test "REST refuses with a 402 naming the key", %{conn: conn, user: user} do
    cap!(user, 1)

    _first = rest_search(conn)
    body = json_response(rest_search(conn), 402)

    assert body["limit_key"] == "ai_searches_per_day"
    assert body["error"] == "limit_exceeded"
    assert Map.has_key?(body, "upgrade_url")
  end

  test "MCP refuses and names the key rather than reporting an outage", %{
    conn: conn,
    user: user
  } do
    cap!(user, 1)

    _first = mcp_search(conn)
    text = json_response(mcp_search(conn), 200)["result"]["content"] |> hd() |> Map.get("text")

    # "Search unavailable." is the outage rendering. A plan limit must be
    # distinguishable from one, or the client retries forever instead of
    # surfacing an upgrade.
    assert text =~ "ai_searches_per_day"
    refute text =~ "unavailable"
  end

  test "one budget spans both transports", %{conn: conn, user: user} do
    cap!(user, 1)

    _spent_over_rest = rest_search(conn)
    text = json_response(mcp_search(conn), 200)["result"]["content"] |> hd() |> Map.get("text")

    assert text =~ "ai_searches_per_day"
  end

  test "create_note still succeeds on a spent budget", %{conn: conn, user: user, vault: vault} do
    cap!(user, 1)
    _spend = rest_search(conn)

    resp =
      post(conn, "/api/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "create_note",
          "arguments" => %{
            "title" => "Degrade",
            "content" => "body",
            "vault_id" => vault.id
          }
        }
      })

    # `auto_place_folder/4` runs a search for folder placement and IS charged,
    # but a spent budget must DEGRADE (default folder) rather than fail the
    # write. Refusing a note creation because the search budget is gone is a
    # worse product than an unplaced note.
    refute json_response(resp, 200)["result"]["isError"]
  end
end
