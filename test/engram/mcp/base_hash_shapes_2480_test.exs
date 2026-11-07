defmodule Engram.MCP.BaseHashShapes2480Test do
  # #2480: the base_hash a read hands out must always be one a write accepts,
  # and a write accepted on it must not delete what the read did not show.
  # Thirteen note shapes, each through three flows (REST GET then POST; REST
  # stale, 409, retry with the 409 hash; MCP stale then get_notes then write),
  # plus a checkpoint between read and write and the served-row window where
  # the read serves the row while the tail holds an edit it hides. Adopted
  # from the round-2 and round-3 adversarial reviews on #2486.
  use EngramWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Engram.Notes.CrdtBridge
  alias Engram.Notes.CrdtRegistry
  alias Yex.Sync.SharedDoc

  @body "# A\n\n## Body\n\nbody text\n"

  setup %{conn: conn} do
    EngramWeb.RateLimiter.reset_buckets!()
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Probe", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    lift_api_rps_cap!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user, vault: vault}
  end

  defp put!(user, vault, path, content) do
    {:ok, _} =
      Engram.Notes.upsert_note(
        user,
        vault,
        %{"path" => path, "content" => content, "mtime" => 1.0},
        actor: "api"
      )
  end

  defp snapshot_of(user, note) do
    {:ok, state} = Engram.Crypto.decrypt_crdt_state(note, user)
    state
  end

  defp base_doc(user, vault, path) do
    {:ok, row} = Engram.Notes.get_note(user, vault, path)
    {:ok, doc} = CrdtBridge.doc_from_state(snapshot_of(user, row))
    {row.id, doc}
  end

  defp land_tail(user, vault, note_id, doc, edit) do
    {:ok, sv} = Yex.encode_state_vector(doc)
    text = Yex.Doc.get_text(doc, CrdtBridge.text_name())
    CrdtBridge.diff_into_text(text, edit.(Yex.Text.to_string(text)))
    {:ok, upd} = Yex.encode_state_as_update(doc, sv)
    st = %{user_id: user.id, vault_id: vault.id, note_id: note_id}
    _ = Engram.Notes.CrdtPersistence.update_v1(st, upd, note_id, doc)
    doc
  end

  defp bad_tail_row(user, vault, note_id) do
    Engram.Repo.with_tenant!(user.id, fn ->
      Engram.Repo.insert_all(Engram.Notes.CrdtUpdateLog, [
        %{
          id: Ecto.UUID.generate(),
          note_id: note_id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: :crypto.strong_rand_bytes(40),
          update_nonce: :crypto.strong_rand_bytes(12),
          inserted_at: DateTime.utc_now()
        }
      ])
    end)
  end

  defp type_into_room(user, vault, path, edit) do
    {:ok, note} = Engram.Notes.get_note(user, vault, path)
    prev = Application.get_env(:engram, Engram.Notes.CrdtCheckpointTimer, [])

    Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer,
      settle_ms: 600_000,
      ceiling_ms: 600_000,
      eager_ms: 600_000
    )

    on_exit(fn -> Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer, prev) end)
    {:ok, room} = CrdtRegistry.ensure_started(user.id, vault.id, note.id)
    on_exit(fn -> CrdtRegistry.terminate_room(note.id) end)

    :ok =
      SharedDoc.update_doc(room, fn doc ->
        text = Yex.Doc.get_text(doc, CrdtBridge.text_name())
        CrdtBridge.diff_into_text(text, edit.(Yex.Text.to_string(text)))
      end)

    room
  end

  defp checkpoint!(user, vault, path) do
    {:ok, row} = Engram.Notes.get_note_row_by_id(user, vault, note_id(user, vault, path))
    {:ok, doc} = CrdtBridge.doc_from_state(snapshot_of(user, row))

    ids =
      Engram.Repo.with_tenant!(user.id, fn ->
        Engram.Repo.all(
          from(l in Engram.Notes.CrdtUpdateLog, where: l.note_id == ^row.id, select: l)
        )
      end)

    _ = Engram.Notes.CrdtPersistence.apply_tail_rows(doc, user, row.id, ids)

    :ok =
      Engram.Notes.CrdtCheckpoint.checkpoint(user.id, vault.id, row.id, doc,
        prune_ids: Enum.map(ids, & &1.id)
      )
  end

  defp note_id(user, vault, path) do
    {:ok, n} = Engram.Notes.get_note(user, vault, path)
    n.id
  end

  defp text_of(user, vault, path) do
    {:ok, fresh} = Engram.Notes.get_note(user, vault, path)
    {:ok, text} = Engram.Notes.authoritative_content(user, fresh)
    text
  end

  # name => path; shape/4 builds it.
  @shapes [
    md_no_tail: "a.md",
    md_tail_edit: "a.md",
    md_live_room: "a.md",
    md_tail_empties: "a.md",
    md_facade_empty_no_tail: "a.md",
    md_facade_empty_tail_adds: "a.md",
    md_frontmatter_only: "a.md",
    md_frontmatter_only_tail: "a.md",
    md_partial_replay: "a.md",
    md_uppercase_ext_tail: "A.MD",
    canvas_no_tail: "b.canvas",
    canvas_tail: "b.canvas",
    txt_tail: "c.txt"
  ]

  defp shape(:md_no_tail, u, v, p), do: put!(u, v, p, @body)

  defp shape(:md_tail_edit, u, v, p) do
    put!(u, v, p, @body)
    {id, doc} = base_doc(u, v, p)
    land_tail(u, v, id, doc, &(&1 <> "LIVE\n"))
  end

  defp shape(:md_live_room, u, v, p) do
    put!(u, v, p, @body)
    type_into_room(u, v, p, &(&1 <> "LIVE\n"))
  end

  defp shape(:md_tail_empties, u, v, p) do
    put!(u, v, p, @body)
    {id, doc} = base_doc(u, v, p)
    land_tail(u, v, id, doc, fn _ -> "" end)
  end

  defp shape(:md_facade_empty_no_tail, u, v, p), do: put!(u, v, p, "")

  defp shape(:md_facade_empty_tail_adds, u, v, p) do
    put!(u, v, p, "")
    {id, doc} = base_doc(u, v, p)
    land_tail(u, v, id, doc, fn _ -> "LIVE\n" end)
  end

  defp shape(:md_frontmatter_only, u, v, p), do: put!(u, v, p, "---\ntags: [a]\n---\n")

  defp shape(:md_frontmatter_only_tail, u, v, p) do
    put!(u, v, p, "---\ntags: [a]\n---\n")
    {id, doc} = base_doc(u, v, p)
    land_tail(u, v, id, doc, &(&1 <> "LIVE\n"))
  end

  defp shape(:md_partial_replay, u, v, p) do
    put!(u, v, p, @body)
    {id, doc} = base_doc(u, v, p)
    land_tail(u, v, id, doc, &(&1 <> "LIVE\n"))
    bad_tail_row(u, v, id)
  end

  defp shape(:md_uppercase_ext_tail, u, v, p) do
    put!(u, v, p, @body)
    {id, doc} = base_doc(u, v, p)
    land_tail(u, v, id, doc, &(&1 <> "LIVE\n"))
  end

  defp shape(:canvas_no_tail, u, v, p), do: put!(u, v, p, ~s({"nodes":[],"edges":[]}))

  defp shape(:canvas_tail, u, v, p) do
    put!(u, v, p, ~s({"nodes":[],"edges":[]}))
    {id, doc} = base_doc(u, v, p)
    land_tail(u, v, id, doc, &(&1 <> "LIVE"))
  end

  defp shape(:txt_tail, u, v, p) do
    put!(u, v, p, "plain text\n")
    {id, doc} = base_doc(u, v, p)
    land_tail(u, v, id, doc, &(&1 <> "LIVE\n"))
  end

  defp get_notes_hash(conn, path) do
    [note] =
      conn
      |> call_tool("get_notes", %{"paths" => [path]})
      |> json_response(200)
      |> get_in(["result", "structuredContent", "notes"])

    note["content_hash"]
  end

  defp mcp_write(conn, path, content, base) do
    conn
    |> call_tool("write_note", %{"path" => path, "content" => content, "base_hash" => base})
    |> json_response(200)
  end

  for {name, path} <- @shapes do
    test "#{name}: REST GET hash writes", %{conn: conn, user: u, vault: v} do
      shape(unquote(name), u, v, unquote(path))
      got = conn |> get("/api/notes/#{URI.encode(unquote(path))}") |> json_response(200)

      resp =
        post(conn, "/api/notes", %{
          path: unquote(path),
          content: (got["content"] || "") <> "SCRIPT\n",
          mtime: 2.0,
          base_hash: got["content_hash"]
        })

      assert resp.status == 200, inspect(resp.resp_body)
    end

    test "#{name}: REST stale -> 409 -> retry with 409 hash writes", %{
      conn: conn,
      user: u,
      vault: v
    } do
      shape(unquote(name), u, v, unquote(path))

      stale =
        post(conn, "/api/notes", %{
          path: unquote(path),
          content: "stale\n",
          mtime: 2.0,
          base_hash: "deadbeef"
        })

      assert stale.status == 409, inspect(stale.resp_body)
      sn = json_response(stale, 409)["server_note"]

      got = conn |> get("/api/notes/#{URI.encode(unquote(path))}") |> json_response(200)
      assert sn["content_hash"] == got["content_hash"]

      resp =
        post(conn, "/api/notes", %{
          path: unquote(path),
          content: (sn["content"] || "") <> "RETRY\n",
          mtime: 3.0,
          base_hash: sn["content_hash"]
        })

      assert resp.status == 200, inspect(resp.resp_body)
    end

    test "#{name}: MCP get_notes hash writes, stale refuses then re-read writes", %{
      conn: conn,
      user: u,
      vault: v
    } do
      shape(unquote(name), u, v, unquote(path))
      stale = mcp_write(conn, unquote(path), "stale\n", "deadbeef")
      assert stale["result"]["isError"], inspect(stale)

      h = get_notes_hash(conn, unquote(path))
      ok = mcp_write(conn, unquote(path), "agent\n", h)
      refute ok["result"]["isError"], inspect(ok)
    end
  end

  test "draining room: checkpoint between GET and POST, GET hash still writes", ctx do
    %{conn: conn, user: u, vault: v} = ctx
    shape(:md_tail_edit, u, v, "a.md")
    got = conn |> get("/api/notes/a.md") |> json_response(200)
    checkpoint!(u, v, "a.md")

    resp =
      post(conn, "/api/notes", %{
        path: "a.md",
        content: got["content"] <> "SCRIPT\n",
        mtime: 2.0,
        base_hash: got["content_hash"]
      })

    assert resp.status == 200, inspect(resp.resp_body)
    t = text_of(u, v, "a.md")
    assert length(String.split(t, "LIVE")) == 2, inspect(t)
  end

  # Q2: the two-hash window. The caller holds the served-row hash while the
  # tail holds edits the served view hides.
  test "md trusted projection: row hash is refused (no window)", ctx do
    %{conn: conn, user: u, vault: v} = ctx
    put!(u, v, "a.md", @body)
    {:ok, row} = Engram.Notes.get_note(u, v, "a.md")
    {id, doc} = base_doc(u, v, "a.md")
    land_tail(u, v, id, doc, &(&1 <> "LIVE\n"))

    resp =
      post(conn, "/api/notes", %{
        path: "a.md",
        content: @body <> "SCRIPT\n",
        mtime: 2.0,
        base_hash: row.content_hash
      })

    assert resp.status == 409
    assert mcp_write(conn, "a.md", "agent\n", row.content_hash)["result"]["isError"]
    assert text_of(u, v, "a.md") =~ "LIVE"
  end

  for {name, path, base} <- [
        {:canvas_tail, "b.canvas", ~s({"nodes":[],"edges":[]})},
        {:md_partial_replay, "a.md", @body},
        {:txt_tail, "c.txt", "plain text\n"}
      ] do
    test "#{name}: REST served-row base keeps the hidden live edit", ctx do
      %{conn: conn, user: u, vault: v} = ctx
      shape(unquote(name), u, v, unquote(path))
      got = conn |> get("/api/notes/#{unquote(path)}") |> json_response(200)
      refute got["content"] =~ "LIVE"

      resp =
        post(conn, "/api/notes", %{
          path: unquote(path),
          content: unquote(base) <> "SCRIPT\n",
          mtime: 2.0,
          base_hash: got["content_hash"]
        })

      assert resp.status == 200, inspect(resp.resp_body)
      t = text_of(u, v, unquote(path))
      assert t =~ "LIVE", inspect(t)
      assert t =~ "SCRIPT", inspect(t)
    end

    test "#{name}: MCP served-row base keeps the hidden live edit", ctx do
      %{conn: conn, user: u, vault: v} = ctx
      shape(unquote(name), u, v, unquote(path))
      h = get_notes_hash(conn, unquote(path))
      ok = mcp_write(conn, unquote(path), unquote(base) <> "AGENT\n", h)
      refute ok["result"]["isError"], inspect(ok)
      t = text_of(u, v, unquote(path))
      assert t =~ "LIVE", inspect(t)
      assert t =~ "AGENT", inspect(t)
    end
  end
end
