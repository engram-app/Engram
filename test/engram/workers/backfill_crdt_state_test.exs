defmodule Engram.Workers.BackfillCrdtStateTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Crypto.Envelope
  alias Engram.Notes.{CrdtBridge, CrdtPersistence, CrdtRegistry, CrdtUpdateLog, Note}
  alias Engram.Vaults.Vault
  alias Engram.Workers.BackfillCrdtState

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "BackfillCrdtStateTest", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  # Reproduces the post-2026-07-06 row shape: content present, CRDT state wiped.
  defp legacy_note(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(
          from(n in Note, where: n.id == ^note.id),
          set: [crdt_state_ciphertext: nil, crdt_state_nonce: nil]
        )
      end)

    note
  end

  # A GENUINE pre-T3.6 row: every envelope written with the EMPTY AAD and the
  # row stamped dek_version = 1, mirroring crypto/aad_rebind_test.exs. Stamping
  # v1 onto a row whose envelopes are already BOUND is not the same thing — such
  # a row fails maybe_decrypt_note_fields outright, so do_seed bails before it
  # can write anything and the test proves nothing.
  defp legacy_v1_note(user, vault, path, content) do
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    {:ok, hash_key} = Crypto.dek_content_hash_key(user)

    {content_ct, content_n} = Envelope.encrypt(content, dek)
    {title_ct, title_n} = Envelope.encrypt("legacy title", dek)
    {path_ct, path_n} = Envelope.encrypt(path, dek)
    {folder_ct, folder_n} = Envelope.encrypt("", dek)
    {tags_ct, tags_n} = Envelope.encrypt(:erlang.term_to_binary([]), dek)

    attrs = %{
      kind: "note",
      content_hash: Crypto.hmac_content_hash(hash_key, content),
      seq: 1,
      mtime: 0.0,
      version: 1,
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
      folder_hmac: Crypto.hmac_field(filter_key, ""),
      tags_ciphertext: tags_ct,
      tags_nonce: tags_n,
      tags_hmac: [],
      dek_version: Crypto.row_version_legacy()
    }

    {:ok, note} =
      Repo.with_tenant(user.id, fn ->
        %Note{}
        |> Ecto.Changeset.cast(attrs, Map.keys(attrs))
        |> Repo.insert!()
      end)

    note
  end

  # An un-checkpointed tail: a Yjs update in crdt_update_log that the note's
  # (NULL) snapshot does not cover yet. Bind replays it onto an empty doc.
  defp seed_tail!(user, vault, note_id, text) do
    {:ok, doc} = CrdtBridge.doc_from_state(nil)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), text)
    {:ok, update} = Yex.encode_state_as_update(doc)
    {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(update, user, note_id)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        %CrdtUpdateLog{}
        |> CrdtUpdateLog.changeset(%{
          note_id: note_id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct,
          update_nonce: nonce
        })
        |> Repo.insert!()
      end)

    :ok
  end

  defp soft_delete_vault!(vault) do
    Repo.update_all(
      from(v in Vault, where: v.id == ^vault.id),
      [set: [deleted_at: DateTime.utc_now(:second)]],
      skip_tenant_check: true
    )
  end

  defp reload(user, note_id) do
    {:ok, note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note_id) end)
    note
  end

  test "seeds crdt_state from content so the note no longer binds empty", ctx do
    %{user: user, vault: vault} = ctx
    note = legacy_note(user, vault, "legacy.md", "IMPORTANT BODY")

    assert %Note{crdt_state_ciphertext: nil} = reload(user, note.id)

    assert :ok =
             perform_job(BackfillCrdtState, %{
               "user_id" => user.id,
               "vault_id" => vault.id,
               "cursor" => "00000000-0000-0000-0000-000000000000"
             })

    seeded = reload(user, note.id)
    refute is_nil(seeded.crdt_state_ciphertext)

    # The seeded state must project the real body — that is the whole point.
    {:ok, state} = Crypto.decrypt_crdt_state(seeded, user)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    assert CrdtBridge.text_of(doc) == "IMPORTANT BODY"
  end

  test "leaves content and version untouched — it backfills representation only", ctx do
    %{user: user, vault: vault} = ctx
    note = legacy_note(user, vault, "legacy.md", "BODY")
    before = reload(user, note.id)

    assert :ok =
             perform_job(BackfillCrdtState, %{
               "user_id" => user.id,
               "vault_id" => vault.id,
               "cursor" => "00000000-0000-0000-0000-000000000000"
             })

    seeded = reload(user, note.id)
    assert seeded.content == before.content
    assert seeded.content_hash == before.content_hash
    assert seeded.version == before.version
  end

  test "is idempotent — a note that already has state is left alone", ctx do
    %{user: user, vault: vault} = ctx

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "fresh.md", "content" => "already seeded"},
        actor: "api"
      )

    before = reload(user, note.id)
    refute is_nil(before.crdt_state_ciphertext)

    assert :ok =
             perform_job(BackfillCrdtState, %{
               "user_id" => user.id,
               "vault_id" => vault.id,
               "cursor" => "00000000-0000-0000-0000-000000000000"
             })

    # Byte-identical: the is_nil predicate must drop it, not re-seed it (a
    # re-seed would discard whatever CRDT history the row already holds).
    after_run = reload(user, note.id)
    assert after_run.crdt_state_ciphertext == before.crdt_state_ciphertext
    assert after_run.crdt_state_nonce == before.crdt_state_nonce
  end

  # Seeding from content here would create a second Yjs lineage on top of the
  # tail's: bind would replay the tail onto the seeded doc and union the two.
  test "a NULL-state note with an un-checkpointed tail is not seeded", ctx do
    %{user: user, vault: vault} = ctx
    note = legacy_note(user, vault, "tailed.md", "BODY")
    :ok = seed_tail!(user, vault, note.id, "BODY")

    assert :ok =
             perform_job(BackfillCrdtState, %{
               "user_id" => user.id,
               "vault_id" => vault.id,
               "cursor" => "00000000-0000-0000-0000-000000000000"
             })

    assert %Note{crdt_state_ciphertext: nil} = reload(user, note.id)
  end

  # A clustered worker whose discovery shows two web nodes (and itself).
  defp put_reach(peers_fun) do
    Application.put_env(:engram, :crdt_room_reach_opts,
      role: :worker,
      query: "engram.local",
      sync: fn -> :ok end,
      self_ip: "10.0.0.9",
      resolver: fn _ -> ["10.0.0.2", "10.0.0.3", "10.0.0.9"] end,
      peers: peers_fun
    )

    on_exit(fn -> Application.delete_env(:engram, :crdt_room_reach_opts) end)
  end

  @full_fleet [:"engram@10.0.0.2", :"engram@10.0.0.3"]

  defp perform_vault(user, vault) do
    perform_job(BackfillCrdtState, %{
      "user_id" => user.id,
      "vault_id" => vault.id,
      "cursor" => "00000000-0000-0000-0000-000000000000"
    })
  end

  # In prod this runs on the worker node and rooms live on web nodes, reached
  # through :global. Partitioned, terminate_room/1 sees no room, so an open
  # empty room would survive the seed. Leave the rows for the next pass.
  test "does not seed when the node cannot reach other nodes' rooms", ctx do
    %{user: user, vault: vault} = ctx
    note = legacy_note(user, vault, "partitioned.md", "BODY")
    put_reach(fn -> [] end)

    assert :ok = perform_vault(user, vault)

    assert %Note{crdt_state_ciphertext: nil} = reload(user, note.id)
    refute_enqueued(worker: BackfillCrdtState)
  end

  test "does not seed when connected to only part of the fleet", ctx do
    %{user: user, vault: vault} = ctx
    note = legacy_note(user, vault, "partial.md", "BODY")
    put_reach(fn -> [:"engram@10.0.0.2"] end)

    assert :ok = perform_vault(user, vault)

    assert %Note{crdt_state_ciphertext: nil} = reload(user, note.id)
  end

  test "seeds on a clustered worker connected to every discovered node", ctx do
    %{user: user, vault: vault} = ctx
    note = legacy_note(user, vault, "joined.md", "BODY")
    put_reach(fn -> @full_fleet end)

    assert :ok = perform_vault(user, vault)

    refute is_nil(reload(user, note.id).crdt_state_ciphertext)
  end

  # The cluster can split mid-batch. Each seed re-checks; once rooms are out of
  # reach the rest of the batch is left untouched, and no successor job is
  # enqueued past them (the next CrdtStateSeed pass starts over).
  test "stops seeding the batch once rooms become unreachable mid-batch", ctx do
    %{user: user, vault: vault} = ctx
    notes = for i <- 1..3, do: legacy_note(user, vault, "flip-#{i}.md", "BODY #{i}")
    Application.put_env(:engram, :crdt_state_backfill_batch_size, 3)
    on_exit(fn -> Application.delete_env(:engram, :crdt_state_backfill_batch_size) end)

    {:ok, calls} = Agent.start_link(fn -> 0 end)

    put_reach(fn ->
      if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0, do: @full_fleet, else: []
    end)

    assert :ok = perform_vault(user, vault)

    [first | rest] = Enum.sort_by(notes, & &1.id)
    refute is_nil(reload(user, first.id).crdt_state_ciphertext)
    for n <- rest, do: assert(%Note{crdt_state_ciphertext: nil} = reload(user, n.id))
    refute_enqueued(worker: BackfillCrdtState)
  end

  # A tail that commits between the batch select and the seed UPDATE: the
  # UPDATE itself must refuse, not only the select.
  test "the seed write refuses a note that gained a tail after selection", ctx do
    %{user: user, vault: vault} = ctx
    note = legacy_note(user, vault, "late-tail.md", "BODY")
    :ok = seed_tail!(user, vault, note.id, "BODY")

    {:ok, count} =
      Repo.with_tenant(user.id, fn ->
        BackfillCrdtState.write_seed(note.id, <<1, 2, 3>>, <<4, 5, 6>>)
      end)

    assert count == 0
    assert %Note{crdt_state_ciphertext: nil} = reload(user, note.id)
  end

  # A room bound on the NULL-state note before the seed holds an EMPTY doc. Left
  # resident, its first edit lands a tail on that empty lineage on top of the
  # seeded snapshot, and the next bind unions two lineages.
  test "evicts a resident room for a note it seeds", ctx do
    %{user: user, vault: vault} = ctx
    note = legacy_note(user, vault, "open.md", "IMPORTANT BODY")

    {:ok, room} = CrdtRegistry.ensure_started(user.id, vault.id, note.id)
    on_exit(fn -> CrdtRegistry.terminate_room(note.id) end)
    ref = Process.monitor(room)

    assert :ok =
             perform_job(BackfillCrdtState, %{
               "user_id" => user.id,
               "vault_id" => vault.id,
               "cursor" => "00000000-0000-0000-0000-000000000000"
             })

    assert_receive {:DOWN, ^ref, :process, ^room, _}, 1_000
    assert CrdtRegistry.lookup(note.id) == nil

    # The next room binds the seeded state, not an empty doc.
    {:ok, fresh} = CrdtRegistry.ensure_started(user.id, vault.id, note.id)

    assert CrdtBridge.text_of(Yex.Sync.SharedDoc.get_doc(fresh)) == "IMPORTANT BODY"
  end

  # A room can flush a tail on its empty lineage in the gap between the seed
  # commit and the kill. That duplicate is not preventable here, so it must at
  # least be visible.
  test "warns of a possible second lineage when a tail exists after the kill", ctx do
    %{user: user, vault: vault} = ctx
    note = legacy_note(user, vault, "raced.md", "BODY")

    refute ExUnit.CaptureLog.capture_log(fn ->
             BackfillCrdtState.warn_if_second_lineage(user.id, note.id)
           end) =~ "possible second lineage"

    :ok = seed_tail!(user, vault, note.id, "TYPED")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        BackfillCrdtState.warn_if_second_lineage(user.id, note.id)
      end)

    assert log =~ "possible second lineage"
    assert log =~ note.id
  end

  # Runs after the seed committed, inside the batch loop: a failure here must
  # not raise out and strand the rest of the vault. A non-UUID id forces the
  # query to raise (Ecto.Query.CastError).
  test "the second-lineage check never raises", ctx do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = BackfillCrdtState.warn_if_second_lineage(ctx.user.id, "not-a-uuid")
      end)

    assert log =~ "second-lineage check failed"
  end

  test "enqueue_missing/0 enqueues only for pairs that still have a seedable note", ctx do
    %{user: user, vault: vault} = ctx
    _ = legacy_note(user, vault, "legacy.md", "BODY")

    assert BackfillCrdtState.enqueue_missing() == 1

    assert_enqueued(worker: BackfillCrdtState, args: %{"user_id" => user.id})
  end

  test "enqueue_missing/0 enqueues nothing when every note already has state", ctx do
    %{user: user, vault: vault} = ctx

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "fresh.md", "content" => "seeded"}, actor: "api")

    assert BackfillCrdtState.enqueue_missing() == 0
  end

  test "enqueue_missing/0 skips a pair whose only NULL-state note has a tail", ctx do
    %{user: user, vault: vault} = ctx
    note = legacy_note(user, vault, "tailed.md", "BODY")
    :ok = seed_tail!(user, vault, note.id, "BODY")

    assert BackfillCrdtState.enqueue_missing() == 0
    refute_enqueued(worker: BackfillCrdtState)
  end

  test "enqueue_missing/0 skips a soft-deleted vault (the worker discards it)", ctx do
    %{user: user, vault: vault} = ctx
    _ = legacy_note(user, vault, "legacy.md", "BODY")
    soft_delete_vault!(vault)

    assert BackfillCrdtState.enqueue_missing() == 0
  end

  test "enqueue_missing/0 skips a deleted note", ctx do
    %{user: user, vault: vault} = ctx
    note = legacy_note(user, vault, "gone.md", "BODY")

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id),
          set: [deleted_at: DateTime.utc_now(:second)]
        )
      end)

    assert BackfillCrdtState.enqueue_missing() == 0
  end

  test "re-enqueues itself when a full batch means more remain", ctx do
    %{user: user, vault: vault} = ctx
    Application.put_env(:engram, :crdt_state_backfill_batch_size, 1)
    on_exit(fn -> Application.delete_env(:engram, :crdt_state_backfill_batch_size) end)

    _ = legacy_note(user, vault, "a.md", "A")
    _ = legacy_note(user, vault, "b.md", "B")

    assert :ok =
             perform_job(BackfillCrdtState, %{
               "user_id" => user.id,
               "vault_id" => vault.id,
               "cursor" => "00000000-0000-0000-0000-000000000000"
             })

    # A full batch must hand off to a successor, else the drain stops after one.
    assert_enqueued(worker: BackfillCrdtState, args: %{"user_id" => user.id})
  end

  test "after the backfill a legacy note binds with its body instead of empty", ctx do
    %{user: user, vault: vault} = ctx
    note = legacy_note(user, vault, "legacy.md", "IMPORTANT BODY")

    # Before: bind produces an EMPTY doc. Opening the note shows blank, and the
    # first keystroke gives the doc real state — at which point the checkpoint
    # legitimately materializes that keystroke over the whole body.
    empty_doc = CrdtBridge.new_doc()

    _ =
      CrdtPersistence.bind(
        %{user_id: user.id, vault_id: vault.id, note_id: note.id},
        note.id,
        empty_doc
      )

    assert CrdtBridge.text_of(empty_doc) == ""

    assert :ok =
             perform_job(BackfillCrdtState, %{
               "user_id" => user.id,
               "vault_id" => vault.id,
               "cursor" => "00000000-0000-0000-0000-000000000000"
             })

    # After: the same bind hydrates the real body. This is the guarantee the
    # removed seed_from_content used to provide, now provided by the DATA.
    healed = CrdtBridge.new_doc()

    _ =
      CrdtPersistence.bind(
        %{user_id: user.id, vault_id: vault.id, note_id: note.id},
        note.id,
        healed
      )

    assert CrdtBridge.text_of(healed) == "IMPORTANT BODY"
  end

  # #1341. Crypto.encrypt_crdt_state/3 binds the AAD to the row id
  # unconditionally, but decrypt_crdt_state/2 picks its AAD from the row's
  # dek_version. Seeding a dek_version = 1 row therefore wrote a ciphertext
  # nothing can read back — the mirror image of #1336 — and this is the exact
  # population the backfill targets, so it was reachable from the documented
  # repair rpc.
  test "migrates a legacy (dek_version = 1) row, then seeds it readably", ctx do
    %{user: user, vault: vault} = ctx
    note = legacy_v1_note(user, vault, "legacy-v1.md", "IMPORTANT BODY")

    assert :ok =
             perform_job(BackfillCrdtState, %{
               "user_id" => user.id,
               "vault_id" => vault.id,
               "cursor" => "00000000-0000-0000-0000-000000000000"
             })

    raw = reload(user, note.id)

    # The row must be migrated, not skipped. Skipping leaves crdt_state NULL,
    # which is the blank-open failure this worker exists to fix.
    assert raw.dek_version == Crypto.row_version_aad_bound()
    refute is_nil(raw.crdt_state_ciphertext)

    # And everything on it must be readable under the version it now claims —
    # a bound ciphertext on a row still claiming v1 is the #1336 shape.
    assert {:ok, state} = Crypto.decrypt_crdt_state(raw, user),
           """
           the backfill seeded an AAD-bound crdt_state onto a row still claiming
           dek_version=#{raw.dek_version}, so CrdtPersistence.bind/3 will raise
           and the note can no longer be opened or written at all.
           """

    assert {:ok, decrypted} = Crypto.maybe_decrypt_note_fields(raw, user)
    assert decrypted.content == "IMPORTANT BODY"
    assert decrypted.path == "legacy-v1.md"

    # The seeded snapshot must project the real body, not an empty doc.
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    assert CrdtBridge.text_of(doc) == "IMPORTANT BODY"
  end
end
