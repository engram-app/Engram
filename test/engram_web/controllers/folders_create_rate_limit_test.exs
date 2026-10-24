defmodule EngramWeb.FoldersCreateRateLimitTest do
  # async: false — the limit is global app env and reset_buckets! wipes every bucket.
  use EngramWeb.ConnCase, async: false

  # #2161: one client POSTed /api/folders at 31/s; every request took the vault
  # change_seq row lock in a pooled transaction and drained the Ecto pool.
  setup %{conn: conn} do
    prev = Application.get_env(:engram, :folder_create_rate_limit)
    Application.put_env(:engram, :folder_create_rate_limit, limit: 2, period_ms: 60_000)
    on_exit(fn -> Application.put_env(:engram, :folder_create_rate_limit, prev) end)
    EngramWeb.RateLimiter.reset_buckets!()
    authed_api_conn(%{conn: conn})
  end

  test "over the per-user limit returns 429 without writing", %{
    conn: conn,
    user: user,
    vault: vault
  } do
    assert conn |> post(~p"/api/folders", %{folder: "A"}) |> json_response(201)
    assert conn |> post(~p"/api/folders", %{folder: "B"}) |> json_response(201)
    seq = Engram.Vaults.current_seq(user.id, vault.id)

    assert %{"error" => "rate_limited"} =
             conn |> post(~p"/api/folders", %{folder: "C"}) |> json_response(429)

    assert Engram.Vaults.current_seq(user.id, vault.id) == seq
    {:ok, folders} = Engram.Notes.list_explicit_folders(user, vault)
    refute "C" in folders
  end

  test "the budget is per user", %{conn: conn} do
    for f <- ~w(A B), do: post(conn, ~p"/api/folders", %{folder: f})
    assert conn |> post(~p"/api/folders", %{folder: "C"}) |> json_response(429)

    %{conn: other} = authed_api_conn(%{conn: build_conn()})
    assert other |> post(~p"/api/folders", %{folder: "C"}) |> json_response(201)
  end

  test "the 429 carries Retry-After", %{conn: conn} do
    for f <- ~w(A B), do: post(conn, ~p"/api/folders", %{folder: f})
    resp = post(conn, ~p"/api/folders", %{folder: "C"})

    assert resp.status == 429
    assert [secs] = get_resp_header(resp, "retry-after")
    assert String.to_integer(secs) in 1..60
  end

  # MCP create_folder arrives as POST /api/mcp, so only a budget in the shared
  # create path can see it (docs/context/mcp-bypasses-path-shaped-plugs.md).
  test "MCP create_folder spends the same per-user budget", %{
    conn: conn,
    user: user,
    vault: vault
  } do
    assert conn |> post(~p"/api/folders", %{folder: "A"}) |> json_response(201)
    user = Engram.Repo.reload!(user)

    assert {:ok, _, _} =
             Engram.MCP.Handlers.handle("create_folder", user, vault, %{"folder" => "B"})

    assert {:error, msg} =
             Engram.MCP.Handlers.handle("create_folder", user, vault, %{"folder" => "C"})

    assert msg =~ "rate limited"
    assert conn |> post(~p"/api/folders", %{folder: "D"}) |> json_response(429)
  end

  # A batch that can write nothing (empty, all-root, over the cap) must not
  # spend the budget a real create needs.
  test "a batch that writes nothing spends no budget", %{conn: conn} do
    assert conn |> post(~p"/api/folders/batch", %{folders: []}) |> json_response(201)
    assert conn |> post(~p"/api/folders/batch", %{folders: [".."]}) |> json_response(201)

    too_many = for i <- 1..501, do: "F#{i}"

    assert %{"error" => "batch_too_large"} =
             conn |> post(~p"/api/folders/batch", %{folders: too_many}) |> json_response(422)

    assert conn |> post(~p"/api/folders", %{folder: "A"}) |> json_response(201)
    assert conn |> post(~p"/api/folders", %{folder: "B"}) |> json_response(201)
  end
end
