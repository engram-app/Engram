defmodule Engram.Notes.NoteBodyWriteTest do
  @moduledoc """
  R8 release N: the app writes `note_bodies` itself (`NoteBody.sync!/3`),
  in the transaction that writes the `notes` body columns, while the
  `notes_sync_body` trigger stays live for the previous release's nodes.

    * "one body write per save": with the trigger live, a save still writes
      the `note_bodies` row ONCE (the trigger's write, then `sync!/3` finds
      the row in step and writes nothing). Counted from
      `pg_stat_xact_user_tables`, which reports this transaction's own
      inserts and updates.
    * "in step without the trigger": the next release drops the trigger, so
      every write path must keep `note_bodies` right on its own. Each test
      disables the trigger (in the sandbox transaction, rolled back after),
      runs one writer and compares every body column against the mapping
      the trigger defines (20261021110200).
    * Row-locked reads take the body from `note_bodies`.

  Not async: `ALTER TABLE ... DISABLE TRIGGER` takes an ACCESS EXCLUSIVE lock
  on `notes` until the sandbox rolls back.
  """
  use Engram.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Engram.Crypto
  alias Engram.Crypto.{AadRebind, DekCache, Envelope}
  alias Engram.DataMigrations.NoteSplit
  alias Engram.Notes
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, CrdtPersistence, CrdtTransport, Note, NoteBody}
  alias Engram.Repo
  alias Engram.Workers.{BackfillCrdtState, ReencodeEnvelopes}

  setup do
    DekCache.invalidate_all()
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Bodies", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp write!(user, vault, path, content, opts \\ []) do
    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => path, "content" => content},
        [actor: "api"] ++ opts
      )

    note
  end

  defp disable_trigger!, do: Repo.query!("ALTER TABLE notes DISABLE TRIGGER notes_sync_body")

  # This transaction's note_bodies tuple writes so far.
  defp body_writes do
    %{rows: [[n]]} =
      Repo.query!("""
      SELECT coalesce(sum(n_tup_ins + n_tup_upd), 0)::int
      FROM pg_stat_xact_user_tables WHERE relname = 'note_bodies'
      """)

    n
  end

  defp writes_during(fun) do
    before = body_writes()
    result = fun.()
    {result, body_writes() - before}
  end

  defp note_count(user_id) do
    Repo.one(
      from(n in Note, where: n.user_id == ^user_id and n.kind == "note", select: count()),
      skip_tenant_check: true
    )
  end

  defp assert_in_step!(user_id) do
    assert note_count(user_id) > 0
    assert Engram.Fixtures.note_body_divergence(user_id) == []
  end

  # `[:engram, :note_body, :sync_wrote]` events this process emits during `fun`.
  defp sync_wrote_during(fun) do
    ref = make_ref()
    me = self()

    :telemetry.attach(
      "sync-wrote-#{inspect(ref)}",
      [:engram, :note_body, :sync_wrote],
      fn _, %{count: n}, _, _ -> if self() == me, do: send(me, {ref, n}) end,
      nil
    )

    try do
      fun.()
      collect(ref, 0)
    after
      :telemetry.detach("sync-wrote-#{inspect(ref)}")
    end
  end

  defp collect(ref, acc) do
    receive do
      {^ref, n} -> collect(ref, acc + n)
    after
      0 -> acc
    end
  end

  defp doc_with(text) do
    doc = Yex.Doc.new()
    text_ref = Yex.Doc.get_text(doc, "content")
    Yex.Text.insert(text_ref, 0, text)
    doc
  end

  describe "one note_bodies write per save, trigger live" do
    test "create inserts the body once", %{user: u, vault: v} do
      {_, n} = writes_during(fn -> write!(u, v, "one.md", "first") end)
      assert n == 1
    end

    test "an update writes the body once", %{user: u, vault: v} do
      write!(u, v, "one.md", "first")
      {_, n} = writes_during(fn -> write!(u, v, "one.md", "second") end)
      assert n == 1
    end

    test "a locked read-modify-write writes the body once", %{user: u, vault: v} do
      write!(u, v, "one.md", "first")

      {_, n} =
        writes_during(fn ->
          assert {{:ok, _}, _} =
                   Notes.rmw_note(u, v, "one.md", &(&1 <> " more"), actor: "api")
        end)

      assert n == 1
    end

    test "a content checkpoint writes the body once", %{user: u, vault: v} do
      note = write!(u, v, "one.md", "first")

      {_, n} =
        writes_during(fn -> CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc_with("x")) end)

      assert n == 1
    end

    test "a rename writes the moved body once and the tombstone once", %{user: u, vault: v} do
      write!(u, v, "one.md", "first")
      {_, n} = writes_during(fn -> {:ok, _} = Notes.rename_note(u, v, "one.md", "two.md") end)
      assert n == 2
    end

    # The signal the next release's gate reads: with the trigger live,
    # `sync!/3` never has anything left to write.
    test "sync! reports no write of its own", %{user: u, vault: v} do
      wrote =
        sync_wrote_during(fn ->
          note = write!(u, v, "one.md", "first")
          write!(u, v, "one.md", "second")
          :ok = CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc_with("x"))
          {:ok, _} = Notes.rename_note(u, v, "one.md", "two.md")
        end)

      assert wrote == 0
    end
  end

  describe "in step without the trigger (the next release drops it)" do
    setup do
      disable_trigger!()
      :ok
    end

    test "create and update", %{user: u, vault: v} do
      # Without the trigger, sync! is the writer, and says so.
      assert sync_wrote_during(fn -> write!(u, v, "a.md", "first") end) == 1
      assert_in_step!(u.id)
      write!(u, v, "a.md", "second")
      assert_in_step!(u.id)
      assert {:ok, %{content: "second"}} = Notes.get_note(u, v, "a.md")
    end

    test "locked read-modify-write", %{user: u, vault: v} do
      write!(u, v, "a.md", "first")

      assert {{:ok, _}, _} =
               Notes.rmw_note(u, v, "a.md", &(&1 <> " more"), actor: "api")

      assert_in_step!(u.id)
    end

    test "delete and restore by rewrite", %{user: u, vault: v} do
      write!(u, v, "a.md", "first")
      assert :ok = Notes.delete_note(u, v, "a.md")
      write!(u, v, "a.md", "back")
      assert_in_step!(u.id)
      assert {:ok, %{content: "back"}} = Notes.get_note(u, v, "a.md")
    end

    test "rename, with its tombstone", %{user: u, vault: v} do
      write!(u, v, "a.md", "first")
      assert {:ok, _} = Notes.rename_note(u, v, "a.md", "b.md")
      assert_in_step!(u.id)
      assert {:ok, %{content: "first"}} = Notes.get_note(u, v, "b.md")
    end

    test "folder rename of a legacy row, with its tombstones", %{user: u, vault: v} do
      legacy = insert_legacy_note!(u, v, "Dir/old.md", "legacy body")
      assert {:ok, _} = Notes.rename_folder(u, v, "Dir", "New")
      assert_in_step!(u.id)
      assert Repo.reload!(legacy, skip_tenant_check: true).dek_version == 2
    end

    test "checkpoints: content, compaction", %{user: u, vault: v} do
      note = write!(u, v, "a.md", "first")
      :ok = CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc_with("changed"))
      assert_in_step!(u.id)

      # The stored doc again: same text, so compaction rewrites the state only.
      {:ok, doc} =
        Repo.with_tenant!(u.id, fn ->
          {:ok, state} = Crypto.decrypt_crdt_state(NoteBody.get(note.id), u)
          CrdtBridge.doc_from_state(state)
        end)

      :ok = CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc)
      assert_in_step!(u.id)
    end

    test "structural (.canvas) checkpoint", %{user: u, vault: v} do
      note = write!(u, v, "board.canvas", ~s({"nodes":[],"edges":[]}))
      :ok = CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc_with("x"))
      assert_in_step!(u.id)
    end

    test "crdt_head: stored, then reset by a tail append", %{user: u, vault: v} do
      note = write!(u, v, "a.md", "first")
      head = String.duplicate("A", 43)
      watermark = ""

      assert {:ok, {1, _}} = CrdtTransport.store_head_if_unchanged(u, note.id, head, watermark)
      assert_in_step!(u.id)

      state = %{user_id: u.id, vault_id: v.id, note_id: note.id, user: u}
      {:ok, update} = Yex.encode_state_as_update(doc_with("typed"))
      _ = CrdtPersistence.update_v1(state, update, note.id, doc_with("typed"))
      assert Repo.reload!(note, skip_tenant_check: true).crdt_head == nil
      assert_in_step!(u.id)
    end

    test "CRDT state backfill seed", %{user: u, vault: v} do
      note = write!(u, v, "a.md", "first")
      {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state("state", u, note.id)

      Repo.with_tenant(u.id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id),
          set: [crdt_state_ciphertext: nil, crdt_state_nonce: nil]
        )

        NoteBody.sync!(note.id, NoteBody.body_fields())
        Repo.query!("DELETE FROM crdt_update_log WHERE note_id = $1", [Ecto.UUID.dump!(note.id)])
        assert BackfillCrdtState.write_seed(note.id, ct, nonce) == 1
      end)

      assert_in_step!(u.id)
    end

    test "AAD rebind of a legacy row", %{user: u, vault: v} do
      insert_legacy_note!(u, v, "legacy/path.md", "legacy body")
      assert :ok = AadRebind.rebind_user(u.id)
      assert_in_step!(u.id)
    end

    test "envelope re-encode", %{user: u, vault: v} do
      note = write!(u, v, "a.md", "first")
      raw = Repo.reload!(note, skip_tenant_check: true)
      {:ok, dek} = Crypto.get_dek(u)
      aad = Crypto.aad_for_row(:notes, :content, note.id)
      {:ok, plain} = Envelope.decrypt(raw.content_ciphertext, raw.content_nonce, dek, aad)
      {ct, nonce} = Envelope.encrypt(plain, dek, aad)

      {1, _} =
        Repo.with_tenant!(u.id, fn ->
          ReencodeEnvelopes.write_row(:notes_content, note.id, raw.content_ciphertext, ct, nonce)
        end)

      assert_in_step!(u.id)
    end

    test "NoteSplit fills a missing body row", %{user: u, vault: v} do
      note = write!(u, v, "a.md", "first")
      Repo.query!("DELETE FROM note_bodies WHERE note_id = $1", [Ecto.UUID.dump!(note.id)])
      NoteSplit.run_pass()
      assert_in_step!(u.id)
    end
  end

  describe "row-locked reads take the body from note_bodies" do
    test "get_note_for_update", %{user: u, vault: v} do
      note = write!(u, v, "a.md", "first")
      nonce = <<1>> <> :crypto.strong_rand_bytes(12)
      ct = :crypto.strong_rand_bytes(40)

      Repo.query!("UPDATE note_bodies SET crdt_ct = $2 WHERE note_id = $1", [
        Ecto.UUID.dump!(note.id),
        nonce <> ct
      ])

      assert {:ok, {:ok, locked}} =
               Repo.with_tenant(u.id, fn -> Notes.get_note_for_update(u, v, "a.md") end)

      assert locked.crdt_state_nonce == nonce
      assert locked.crdt_state_ciphertext == ct
    end
  end

  # Hand-built legacy note (dek_version 1, empty AAD), as AadRebindTest does.
  # A fixture writes `notes` directly, so it puts its body row in place the
  # way every writer does.
  defp insert_legacy_note!(user, vault, path, content) do
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    folder = Path.dirname(path)
    enc = &Envelope.encrypt(&1, dek)
    {content_ct, content_n} = enc.(content)
    {title_ct, title_n} = enc.("title")
    {path_ct, path_n} = enc.(path)
    {folder_ct, folder_n} = enc.(folder)
    {tags_ct, tags_n} = enc.(:erlang.term_to_binary([]))

    note =
      Repo.insert!(
        %Note{
          content_hash: "h",
          seq: 1,
          mtime: 0.0,
          user_id: user.id,
          vault_id: vault.id,
          content_ciphertext: content_ct,
          content_nonce: content_n,
          title_ciphertext: title_ct,
          title_nonce: title_n,
          path_ciphertext: path_ct,
          path_nonce: path_n,
          path_hmac: Crypto.hmac_field(filter_key, path),
          folder_ciphertext: folder_ct,
          folder_nonce: folder_n,
          folder_hmac: Crypto.hmac_field(filter_key, folder),
          tags_ciphertext: tags_ct,
          tags_nonce: tags_n,
          tags_hmac: [],
          dek_version: 1
        },
        skip_tenant_check: true
      )

    NoteBody.sync!(note.id, NoteBody.body_fields())
    note
  end
end

defmodule Engram.Notes.NoteBodyRotationTest do
  @moduledoc """
  DEK rotation reads each note's body from `note_bodies` (under the notes
  row lock) and keeps `note_bodies` in step on its own.
  """
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Crypto.{DekCache, Envelope, UserDekRotation}
  alias Engram.Notes
  alias Engram.Repo

  setup do
    DekCache.invalidate_all()
    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.stub(bypass, "POST", "/collections/engram_notes/points/scroll", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"result" => %{"points" => [], "next_page_offset" => nil}})
      )
    end)

    Bypass.stub(bypass, "POST", "/collections/engram_notes/points/payload", fn conn ->
      Plug.Conn.send_resp(conn, 200, ~s({"result": {"status": "completed"}, "status": "ok"}))
    end)

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture(dek_version: 1)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Rot", Ecto.UUID.generate())

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "r.md", "content" => "from notes"}, actor: "api")

    %{user: user, vault: vault, note: note}
  end

  test "rotation rewraps the body note_bodies holds", %{user: u, vault: v, note: note} do
    {:ok, dek} = Crypto.get_dek(u)
    aad = Crypto.aad_for_row(:notes, :content, note.id)
    {ct, nonce} = Envelope.encrypt("from bodies", dek, aad)

    Repo.query!("UPDATE note_bodies SET content_ct = $2 WHERE note_id = $1", [
      Ecto.UUID.dump!(note.id),
      Envelope.merge(nonce, ct)
    ])

    assert :ok = UserDekRotation.rotate_user(u.id)
    DekCache.invalidate_all()
    u = Engram.Accounts.get_user!(u.id)
    assert {:ok, %{content: "from bodies"}} = Notes.get_note(u, v, "r.md")
  end

  test "rotation keeps note_bodies in step without the trigger", %{user: u, vault: v} do
    Repo.query!("ALTER TABLE notes DISABLE TRIGGER notes_sync_body")
    assert :ok = UserDekRotation.rotate_user(u.id)
    assert Engram.Fixtures.note_body_divergence(u.id) == []
    DekCache.invalidate_all()
    u = Engram.Accounts.get_user!(u.id)
    assert {:ok, %{content: "from notes"}} = Notes.get_note(u, v, "r.md")
  end
end
