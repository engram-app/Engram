defmodule Engram.Notes.NoteBodyWriteTest do
  @moduledoc """
  R8: the app writes `note_bodies` itself (`NoteBody.sync!/3`), in the
  transaction that writes the `notes` body columns. Release N+1 dropped the
  `notes_sync_body` trigger (20261104000000), so `sync!/3` is the only
  writer.

    * "the trigger is gone": a raw `notes` write that skips `sync!/3`
      leaves `note_bodies` as it was.
    * "one body write per save": a save writes the `note_bodies` row ONCE,
      and that write is `sync!/3`'s. Counted from `pg_stat_xact_user_tables`,
      which reports this transaction's own inserts and updates.
    * "in step with sync! as the only writer": each test runs one writer
      and compares every body column against the mapping the dropped
      trigger defined (20261021110200).
    * Row-locked reads take the body from `note_bodies`.
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

  # This transaction's note_bodies tuple writes so far.
  defp body_writes do
    %{rows: [[n]]} =
      Repo.query!("""
      SELECT coalesce(sum(n_tup_ins + n_tup_upd), 0)::int
      FROM pg_stat_xact_user_tables WHERE relname = 'note_bodies'
      """)

    n
  end

  # This transaction's note_bodies writes during `fun`, asserting every one
  # was sync!'s own (the telemetry the release gate reads).
  defp sync_writes_during(fun) do
    before = body_writes()
    wrote = sync_wrote_during(fun)
    n = body_writes() - before
    assert wrote == n
    n
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

  describe "the trigger is gone" do
    test "a raw notes write that skips sync! leaves note_bodies as it was",
         %{user: u, vault: v} do
      note = write!(u, v, "one.md", "first")
      id = Ecto.UUID.dump!(note.id)
      body = fn -> Repo.query!("SELECT content_ct FROM note_bodies WHERE note_id = $1", [id]) end
      before = body.()

      Repo.query!(
        "UPDATE notes SET content_ciphertext = $2, content_nonce = $3 WHERE id = $1",
        [id, :crypto.strong_rand_bytes(40), <<1>> <> :crypto.strong_rand_bytes(12)]
      )

      assert body.() == before
      assert [{_, [:content]}] = Engram.Fixtures.note_body_divergence(u.id)
    end
  end

  describe "one note_bodies write per save" do
    test "create inserts the body once", %{user: u, vault: v} do
      assert sync_writes_during(fn -> write!(u, v, "one.md", "first") end) == 1
    end

    test "an update writes the body once", %{user: u, vault: v} do
      write!(u, v, "one.md", "first")
      assert sync_writes_during(fn -> write!(u, v, "one.md", "second") end) == 1
    end

    test "a locked read-modify-write writes the body once", %{user: u, vault: v} do
      write!(u, v, "one.md", "first")

      assert sync_writes_during(fn ->
               assert {{:ok, _}, _} =
                        Notes.rmw_note(u, v, "one.md", &(&1 <> " more"), actor: "api")
             end) == 1
    end

    test "a content checkpoint writes the body once", %{user: u, vault: v} do
      note = write!(u, v, "one.md", "first")

      assert sync_writes_during(fn ->
               CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc_with("x"))
             end) == 1
    end

    test "a rename writes the moved body once and the tombstone once", %{user: u, vault: v} do
      write!(u, v, "one.md", "first")

      assert sync_writes_during(fn ->
               {:ok, _} = Notes.rename_note(u, v, "one.md", "two.md")
             end) == 2
    end
  end

  describe "in step with sync! as the only writer" do
    test "create and update", %{user: u, vault: v} do
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
          ReencodeEnvelopes.write_row(
            :notes_content,
            note.id,
            {raw.content_ciphertext, raw.content_nonce},
            ct,
            nonce
          )
        end)

      assert_in_step!(u.id)
    end

    test "the insert_note! fixture", %{user: u, vault: v} do
      Engram.Fixtures.insert_note!(u, v, %{"path" => "fixture.md"})
      assert_in_step!(u.id)
    end

    test "the insert_notes! fixture, attrs and built notes", %{user: u, vault: v} do
      ids =
        Engram.Fixtures.insert_notes!(u, v, [
          %{"path" => "bulk/a.md", "embed_hash" => nil},
          %{path: "bulk/b.md"},
          build(:note)
        ])

      assert length(ids) == 3
      assert {:ok, %{id: id}} = Notes.get_note(u, v, "bulk/b.md")
      assert id == Enum.at(ids, 1)

      # Every note, the built one too (its factory seq is a placeholder),
      # takes its seq from the vault's allocator block, in order.
      %{rows: seqs} =
        Repo.query!(
          "SELECT n.seq, v.change_seq FROM unnest($1::uuid[]) WITH ORDINALITY AS i(id, ord) " <>
            "JOIN notes n ON n.id = i.id JOIN vaults v ON v.id = n.vault_id ORDER BY i.ord",
          [Enum.map(ids, &Ecto.UUID.dump!/1)]
        )

      [[_, last] | _] = seqs
      assert Enum.map(seqs, &hd/1) == Enum.to_list((last - 2)..last)
      assert_in_step!(u.id)
    end

    test "NoteSplit fills a missing body row", %{user: u, vault: v} do
      note = write!(u, v, "a.md", "first")
      Repo.query!("DELETE FROM note_bodies WHERE note_id = $1", [Ecto.UUID.dump!(note.id)])
      NoteSplit.run_pass()
      assert_in_step!(u.id)
    end
  end

  @doc false
  # Makes every later `notes` write in this test store a stale content
  # ciphertext and a NULL CRDT state ciphertext (nonces as written), as a
  # release that stops writing those columns would leave them. A test-only
  # trigger, rolled back with the sandbox. A body built by copying from
  # `notes` then holds the wrong bytes; one written from the writer's own
  # values does not.
  def stale_notes_body! do
    Repo.query!("""
    CREATE FUNCTION r8_test_stale_notes_body() RETURNS trigger AS $$
    BEGIN
      IF NEW.kind = 'note' THEN
        NEW.content_ciphertext := '\\x00'::bytea;
        NEW.crdt_state_ciphertext := NULL;
      END IF;
      RETURN NEW;
    END $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER zz_r8_test_stale_notes_body BEFORE INSERT OR UPDATE ON notes
    FOR EACH ROW EXECUTE FUNCTION r8_test_stale_notes_body()
    """)
  end

  defp raw_notes(id) do
    %{rows: [row]} =
      Repo.query!(
        "SELECT content_ciphertext, crdt_state_ciphertext, crdt_state_nonce FROM notes WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    row
  end

  defp body_row(id) do
    Repo.query!(
      "SELECT user_id, key_version, content_ct, crdt_ct, crdt_head FROM note_bodies WHERE note_id = $1",
      [Ecto.UUID.dump!(id)]
    ).rows
  end

  defp crdt_state!(u, id) do
    {:ok, state} =
      Repo.with_tenant!(u.id, fn -> Crypto.decrypt_crdt_state(NoteBody.get(id), u) end)

    state
  end

  describe "R8(b1): the body is what the writer wrote, not a copy of notes" do
    test "create", %{user: u, vault: v} do
      stale_notes_body!()
      note = write!(u, v, "a.md", "first")
      assert [<<0>>, nil, _] = raw_notes(note.id)
      assert {:ok, %{content: "first"}} = Notes.get_note(u, v, "a.md")
      assert is_binary(crdt_state!(u, note.id))
    end

    test "update", %{user: u, vault: v} do
      note = write!(u, v, "a.md", "first")
      stale_notes_body!()
      write!(u, v, "a.md", "second")
      assert [<<0>>, nil, _] = raw_notes(note.id)
      assert {:ok, %{content: "second"}} = Notes.get_note(u, v, "a.md")
      assert is_binary(crdt_state!(u, note.id))
    end

    test "content checkpoint, then compaction", %{user: u, vault: v} do
      note = write!(u, v, "a.md", "first")
      stale_notes_body!()
      :ok = CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc_with("changed"))
      assert {:ok, %{content: text}} = Notes.get_note(u, v, "a.md")
      assert text =~ "changed"
      {:ok, doc} = CrdtBridge.doc_from_state(crdt_state!(u, note.id))
      :ok = CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc)
      assert [<<0>>, nil, _] = raw_notes(note.id)
      assert {:ok, %{content: ^text}} = Notes.get_note(u, v, "a.md")
      assert is_binary(crdt_state!(u, note.id))
    end

    test "rename, with its tombstone", %{user: u, vault: v} do
      note = write!(u, v, "a.md", "first")
      stale_notes_body!()
      assert {:ok, _} = Notes.rename_note(u, v, "a.md", "b.md")
      assert [<<0>>, _, _] = raw_notes(note.id)
      assert {:ok, %{content: "first"}} = Notes.get_note(u, v, "b.md")
      assert is_binary(crdt_state!(u, note.id))
    end
  end

  describe "R8(b1): an old release's copy from notes cannot erase a body" do
    # 0.74's DEK rotation copies every body field from `notes`
    # (`NoteBody.sync!(ids, body_fields())`, user_dek_rotation.ex:294), and
    # `NoteSplit` heals by the same copy. Beside a release that stops writing
    # the `notes` ciphertexts, those columns are NULL or stale while the
    # nonces stay current.
    setup %{user: u, vault: v} do
      note = write!(u, v, "a.md", "first")
      %{note: note, id: Ecto.UUID.dump!(note.id), before: body_row(note.id)}
    end

    defp old_copy!(note_id) do
      NoteBody.sync!([note_id], NoteBody.body_fields())
      NoteSplit.run_pass()
    end

    defp assert_body_kept!(ctx) do
      assert body_row(ctx.note.id) == ctx.before
      assert {:ok, %{content: "first"}} = Notes.get_note(ctx.user, ctx.vault, "a.md")
      assert is_binary(crdt_state!(ctx.user, ctx.note.id))
    end

    test "NULL notes ciphertexts", ctx do
      Repo.query!(
        "UPDATE notes SET content_ciphertext = NULL, crdt_state_ciphertext = NULL WHERE id = $1",
        [ctx.id]
      )

      old_copy!(ctx.note.id)
      assert_body_kept!(ctx)
    end

    test "stale notes ciphertexts under current nonces", ctx do
      Repo.query!(
        "UPDATE notes SET content_ciphertext = $2, crdt_state_ciphertext = $2 WHERE id = $1",
        [ctx.id, :crypto.strong_rand_bytes(40)]
      )

      old_copy!(ctx.note.id)
      assert_body_kept!(ctx)
    end

    test "NULL ciphertexts while the copy rewrites the row (key version out of step)", ctx do
      Repo.query!(
        "UPDATE notes SET content_ciphertext = NULL, crdt_state_ciphertext = NULL WHERE id = $1",
        [ctx.id]
      )

      [[_, kv | _]] = ctx.before
      Repo.query!("UPDATE note_bodies SET key_version = $2 WHERE note_id = $1", [ctx.id, kv + 1])
      assert NoteBody.sync!([ctx.note.id], NoteBody.body_fields()) == 1
      assert_body_kept!(ctx)
    end
  end

  describe "R8(b1) schema prep" do
    test "a nonce-only CRDT state write resets the head; nulling the ciphertext does not",
         %{user: u, vault: v} do
      note = write!(u, v, "a.md", "first")
      id = Ecto.UUID.dump!(note.id)
      head = String.duplicate("A", 43)
      head_of = fn -> Repo.query!("SELECT crdt_head FROM notes WHERE id = $1", [id]).rows end

      Repo.query!("UPDATE notes SET crdt_head = $2 WHERE id = $1", [id, head])
      Repo.query!("UPDATE notes SET crdt_state_ciphertext = NULL WHERE id = $1", [id])
      assert head_of.() == [[head]]

      Repo.query!("UPDATE notes SET crdt_state_nonce = $2 WHERE id = $1", [
        id,
        <<1>> <> :crypto.strong_rand_bytes(12)
      ])

      assert head_of.() == [[nil]]
    end

    test "a note may drop its content ciphertext but not also its nonce", %{user: u, vault: v} do
      note = write!(u, v, "a.md", "first")
      id = Ecto.UUID.dump!(note.id)

      assert {:ok, _} =
               Repo.query("UPDATE notes SET content_ciphertext = NULL WHERE id = $1", [id],
                 mode: :savepoint
               )

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query("UPDATE notes SET content_nonce = NULL WHERE id = $1", [id],
                 mode: :savepoint
               )
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

  test "R8(b1): rotation writes the rewrapped body, not a copy of notes",
       %{user: u, vault: v, note: note} do
    Engram.Notes.NoteBodyWriteTest.stale_notes_body!()
    assert :ok = UserDekRotation.rotate_user(u.id)
    assert [[<<0>>]] = content_in_notes(note.id)
    DekCache.invalidate_all()
    u = Engram.Accounts.get_user!(u.id)
    assert {:ok, %{content: "from notes"}} = Notes.get_note(u, v, "r.md")
  end

  test "R8(b1): a resumed rotation keeps a body already rotated, whatever notes holds",
       %{user: u, vault: v, note: note} do
    new_dek = Engram.Test.FixedDekProvider.install!()
    aad = Crypto.aad_for_row(:notes, :content, note.id)
    {ct, nonce} = Envelope.encrypt("rotated by the crashed run", new_dek, aad)
    id = Ecto.UUID.dump!(note.id)

    # The crashed run rewrapped the body; `notes` still holds the old copy.
    Repo.query!("UPDATE note_bodies SET content_ct = $2 WHERE note_id = $1", [
      id,
      Envelope.merge(nonce, ct)
    ])

    assert :ok = UserDekRotation.rotate_user(u.id)
    DekCache.invalidate_all()
    u = Engram.Accounts.get_user!(u.id)
    assert {:ok, %{content: "rotated by the crashed run"}} = Notes.get_note(u, v, "r.md")
  end

  defp content_in_notes(id),
    do:
      Repo.query!("SELECT content_ciphertext FROM notes WHERE id = $1", [Ecto.UUID.dump!(id)]).rows

  test "rotation keeps note_bodies in step", %{user: u, vault: v} do
    assert :ok = UserDekRotation.rotate_user(u.id)
    assert Engram.Fixtures.note_body_divergence(u.id) == []
    DekCache.invalidate_all()
    u = Engram.Accounts.get_user!(u.id)
    assert {:ok, %{content: "from notes"}} = Notes.get_note(u, v, "r.md")
  end
end
