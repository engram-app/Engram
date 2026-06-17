defmodule EngramWeb.SyncChangesTest do
  use EngramWeb.ConnCase, async: true
  alias Engram.{Attachments, Notes}

  setup %{conn: conn} do
    user = insert(:user)
    vault = insert(:vault, user: user, is_default: true)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "k")
    grant_api_write!(user)

    authed =
      conn
      |> put_req_header("authorization", "Bearer #{api_key}")
      |> put_req_header("x-device-id", "dev-1")

    %{conn: authed, user: user, vault: vault}
  end

  test "pulls notes+attachments merged by seq, paginates, records watermark", %{
    conn: conn,
    user: user,
    vault: vault
  } do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "n1.md", "content" => "x"})

    {:ok, _} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => "a.png",
        "content_base64" => Base.encode64("p"),
        "mime_type" => "image/png"
      })

    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "n2.md", "content" => "y"})

    p1 = conn |> get(~p"/api/sync/changes?limit=2") |> json_response(200)
    assert length(p1["changes"]) == 2
    assert p1["has_more"] == true
    assert Enum.all?(p1["changes"], &(&1["type"] in ["note", "attachment"]))
    # strictly increasing seq across the merged page
    seqs = Enum.map(p1["changes"], & &1["seq"])
    assert seqs == Enum.sort(seqs)

    p2 =
      conn |> get(~p"/api/sync/changes?cursor=#{p1["next_cursor"]}&limit=2") |> json_response(200)

    assert length(p2["changes"]) == 1 and p2["has_more"] == false

    # pull-carries-ack: the watermark is the seq the SECOND pull's cursor
    # carried in (= what the client had applied = page 1's last seq), NOT the
    # new page's max seq. With seqs 1,2,3 and page size 2, page 2's incoming
    # cursor seq is 2, so the recorded watermark is exactly 2. Asserting the
    # exact value guards against a regression to recording the page max (3).
    {:ok, row} =
      Engram.Repo.with_tenant(user.id, fn ->
        Engram.Repo.get_by(Engram.Sync.DeviceCursor, vault_id: vault.id, device_id: "dev-1")
      end)

    assert row.last_seq == 2
  end

  test "malformed cursor -> 400", %{conn: conn} do
    # A valid query param that is NOT a valid opaque cursor token (decodes but
    # has no "<seq>:<id>" shape) — exercises decode_cursor's {:error, :invalid_cursor}.
    assert conn |> get(~p"/api/sync/changes?cursor=not-a-real-cursor") |> json_response(400)
  end

  test "manifest includes current change_seq", %{conn: conn, user: user, vault: vault} do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "n.md", "content" => "x"})
    body = conn |> get(~p"/api/sync/manifest") |> json_response(200)
    assert is_integer(body["change_seq"])
    # exactly one write bumped the per-vault counter from 0 → 1
    assert body["change_seq"] == 1
  end

  test "fields=meta omits note content but keeps content_hash + path", %{
    conn: conn,
    user: user,
    vault: vault
  } do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "n.md", "content" => "secret body"})

    body = conn |> get(~p"/api/sync/changes?fields=meta") |> json_response(200)
    note = Enum.find(body["changes"], &(&1["type"] == "note"))

    assert note["content"] == nil
    assert is_binary(note["content_hash"])
    assert note["path"] == "n.md"
  end

  test "default (no fields param) returns full note content", %{
    conn: conn,
    user: user,
    vault: vault
  } do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "n.md", "content" => "secret body"})

    body = conn |> get(~p"/api/sync/changes") |> json_response(200)
    note = Enum.find(body["changes"], &(&1["type"] == "note"))

    assert note["content"] == "secret body"
  end

  test "an unknown fields value falls back to full content (lenient, forward-compatible)", %{
    conn: conn,
    user: user,
    vault: vault
  } do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "n.md", "content" => "secret body"})

    body = conn |> get(~p"/api/sync/changes?fields=bogus") |> json_response(200)
    note = Enum.find(body["changes"], &(&1["type"] == "note"))

    assert note["content"] == "secret body"
  end
end
