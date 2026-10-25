defmodule Engram.Notes.LineageAuditTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import ExUnit.CaptureLog

  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Notes
  alias Engram.Notes.{CrdtBridge, CrdtRegistry, CrdtTransport, CrdtUpdateLog, LineageAudit, Note}
  alias Engram.Repo
  alias Engram.Test.LogCapture

  setup do
    {user, vault} = owner("LineageAudit")
    %{user: user, vault: vault}
  end

  defp owner(name) do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, name, Ecto.UUID.generate())
    {user, vault}
  end

  defp set_note(user, note_id, fields) do
    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note_id), set: fields)
      end)
  end

  # Moves the whole snapshot into one update-log row: a never-checkpointed note.
  # The row is stamped with `vault` (pass a foreign one for the #1318 shape).
  defp log_only!(user, vault, note_id) do
    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note_id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, user)
    {:ok, dek} = Crypto.get_dek(user)
    {ct, nonce} = Envelope.encrypt(state, dek, Crypto.aad_for_row(:notes, :crdt_state, note_id))

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.insert!(%CrdtUpdateLog{
          note_id: note_id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct,
          update_nonce: nonce,
          inserted_at: DateTime.utc_now()
        })
      end)

    set_note(user, note_id, crdt_state_ciphertext: nil, crdt_state_nonce: nil)
  end

  defp note(user, vault, path, content) do
    {:ok, note} = Notes.upsert_note(user, vault, %{path: path, content: content}, actor: "api")
    on_exit(fn -> CrdtRegistry.terminate_room(note.id) end)
    note
  end

  # What the fresh-device bug sent: the whole body seeded into an EMPTY doc.
  defp rival_seed(user, vault, note_id, text) do
    fresh = CrdtBridge.new_doc()
    CrdtBridge.ingest_plaintext(fresh, text)
    {:ok, update} = Yex.encode_state_as_update(fresh)
    {:ok, _} = CrdtTransport.apply_update(user, vault, note_id, update)
  end

  # An ordinary edit on the server's lineage.
  defp edit(user, vault, note_id, text) do
    {:ok, %{update: full}} = CrdtTransport.read_delta(user, vault, note_id, nil)
    client = CrdtBridge.new_doc()
    :ok = Yex.apply_update(client, full)
    sv = Yex.encode_state_vector!(client)
    CrdtBridge.ingest_plaintext(client, text)
    {:ok, update} = Yex.encode_state_as_update(client, sv)
    {:ok, _} = CrdtTransport.apply_update(user, vault, note_id, update)
  end

  # A client on the server's lineage selects the whole body and types `text`.
  defp clear_and_retype(user, vault, note_id, text) do
    {:ok, %{update: full}} = CrdtTransport.read_delta(user, vault, note_id, nil)
    client = CrdtBridge.new_doc()
    :ok = Yex.apply_update(client, full)
    sv = Yex.encode_state_vector!(client)
    body = Yex.Doc.get_text(client, CrdtBridge.text_name())
    Yex.Text.delete(body, 0, String.length(Yex.Text.to_string(body)))
    Yex.Text.insert(body, 0, text)
    {:ok, update} = Yex.encode_state_as_update(client, sv)
    {:ok, _} = CrdtTransport.apply_update(user, vault, note_id, update)
  end

  test "an edited note is one lineage", %{user: user, vault: vault} do
    n = note(user, vault, "A/Clean.md", "first body line.\n")
    edit(user, vault, n.id, "first body line.\nsecond line.\n")

    assert {:ok, %{note_id: id, live_root_count: 1, root_count: 1, root_client_count: 1}} =
             LineageAudit.scan_note(user, vault, n.id)

    assert id == n.id
  end

  test "RIVAL: a fresh-device seed is two live lineages", %{user: user, vault: vault} do
    n = note(user, vault, "A/Doubled.md", "first body line.\n")
    rival_seed(user, vault, n.id, "first body line.\nsecond line.\n")

    assert {:ok,
            %{live_root_count: 2, root_client_count: 2, root_count: 2, lineage_lengths: lengths}} =
             LineageAudit.scan_note(user, vault, n.id)

    assert length(lengths) == 2
    assert {:ok, %{rivals: [%{note_id: id}], suspects: []}} = LineageAudit.run(user_id: user.id)
    assert id == n.id
  end

  test "HEALTHY: a cleared-and-retyped note is one dead root", %{user: user, vault: vault} do
    n = note(user, vault, "A/Retyped.md", "old text")
    clear_and_retype(user, vault, n.id, "new text")

    # Retyping hangs off the deleted structs: still one lineage, now dead.
    assert {:ok, %{live_root_count: 0, root_count: 1}} =
             LineageAudit.scan_note(user, vault, n.id)

    assert {:ok, %{rivals: [], suspects: []}} = LineageAudit.run(user_id: user.id)
  end

  test "SUSPECT: a fresh seed over a cleared-and-retyped note", %{user: user, vault: vault} do
    # The I1 false negative: the original root is dead and the rival is live,
    # so only ONE live root remains while the body reads "new textnew text".
    n = note(user, vault, "A/Reseeded.md", "old text")
    clear_and_retype(user, vault, n.id, "new text")
    rival_seed(user, vault, n.id, "new text")

    assert {:ok, %{live_root_count: 1, root_count: 2}} =
             LineageAudit.scan_note(user, vault, n.id)

    assert {:ok, %{rivals: [], suspects: [%{note_id: id}]}} = LineageAudit.run(user_id: user.id)
    assert id == n.id
  end

  test "SUSPECT: a doubled note whose rival copy was deleted", %{user: user, vault: vault} do
    n = note(user, vault, "A/Cleaned.md", "first body line.\n")
    rival = "first body line.\nsecond line.\n"
    rival_seed(user, vault, n.id, rival)

    # The user deletes the duplicate by hand, on the server's lineage.
    {:ok, %{update: full}} = CrdtTransport.read_delta(user, vault, n.id, nil)
    client = CrdtBridge.new_doc()
    :ok = Yex.apply_update(client, full)
    sv = Yex.encode_state_vector!(client)
    text = Yex.Doc.get_text(client, CrdtBridge.text_name())
    at = if String.starts_with?(Yex.Text.to_string(text), rival), do: 0, else: 17
    Yex.Text.delete(text, at, String.length(rival))
    {:ok, update} = Yex.encode_state_as_update(client, sv)
    {:ok, _} = CrdtTransport.apply_update(user, vault, n.id, update)

    # Was "one lineage" while only live roots counted. The deleted copy is a
    # dead root beside a live one, the same shape as a fresh seed over a
    # cleared note (above), whose body IS doubled. The audit cannot tell them
    # apart without reading text, so both are suspects for triage.
    assert {:ok, %{live_root_count: 1, root_count: 2, root_client_count: 2}} =
             LineageAudit.scan_note(user, vault, n.id)
  end

  test "a note whose state lives only in the update log is scanned", %{user: user, vault: vault} do
    n = note(user, vault, "A/LogOnly.md", "body\n")
    CrdtRegistry.terminate_room(n.id)
    log_only!(user, vault, n.id)

    assert {:ok, %{root_count: 1}} = LineageAudit.scan_note(user, vault, n.id)
    assert {:ok, %{scanned: 1, unreadable_count: 0}} = LineageAudit.run(user_id: user.id)
  end

  test "a note with neither snapshot nor log rows is not counted", %{user: user, vault: vault} do
    n = note(user, vault, "A/Empty.md", "body\n")
    CrdtRegistry.terminate_room(n.id)
    set_note(user, n.id, crdt_state_ciphertext: nil, crdt_state_nonce: nil)

    assert {:ok, %{scanned: 0}} = LineageAudit.run(user_id: user.id)
  end

  test "a log-only note whose rows are all in a foreign vault is named :not_found", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, foreign, _} = Engram.Vaults.register_vault(user, "Foreign", Ecto.UUID.generate())
    n = note(user, vault, "A/Foreign.md", "body\n")
    CrdtRegistry.terminate_room(n.id)
    # #1318 shape: the note's only state is a log row stamped with another vault.
    log_only!(user, foreign, n.id)

    capture_log(fn ->
      assert {:error, :not_found} = LineageAudit.scan_note(user, vault, n.id)

      # Selected, not dropped: the run names it instead of omitting it.
      assert {:ok, %{scanned: 1, rivals: [], suspects: [], unreadable: unreadable}} =
               LineageAudit.run(user_id: user.id)

      assert unreadable == [%{note_id: n.id, reason: :not_found}]
    end)
  end

  test "a tail row that decrypts but will not apply is :undecodable", ctx do
    %{user: user, vault: vault} = ctx
    n = note(user, vault, "C/BadRow.md", "x\n")
    CrdtRegistry.terminate_room(n.id)
    {:ok, dek} = Crypto.get_dek(user)
    # Decrypts fine (right key, right AAD); the plaintext is not a Yjs update.
    {ct, nonce} =
      Envelope.encrypt(<<255, 255, 255>>, dek, Crypto.aad_for_row(:notes, :crdt_state, n.id))

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.insert!(%CrdtUpdateLog{
          note_id: n.id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct,
          update_nonce: nonce,
          inserted_at: DateTime.utc_now()
        })
      end)

    assert {:error, :undecodable} = LineageAudit.scan_note(user, vault, n.id)
  end

  test "a scan that raises is unreadable as :error, and the run goes on", ctx do
    %{user: user, vault: vault} = ctx
    bad = note(user, vault, "C/Raises.md", "x\n")
    good = note(user, vault, "C/Fine.md", "y\n")

    scan = fn u, v, id ->
      if id == bad.id, do: raise(ArgumentError, "boom"), else: LineageAudit.scan_note(u, v, id)
    end

    assert {:ok, %{scanned: 2, unreadable: [%{note_id: id, reason: :error}]} = result} =
             LineageAudit.run(user_id: user.id, scan: scan)

    assert id == bad.id
    refute good.id in Enum.map(result.unreadable, & &1.note_id)
    refute inspect(result) =~ "ArgumentError"
    refute inspect(result) =~ "boom"
  end

  test "run/1 writes nothing and starts no room or job", %{user: user, vault: vault} do
    n = note(user, vault, "G/ReadOnly.md", "a\n")
    rival_seed(user, vault, n.id, "a\nb\n")

    # terminate_room is an async :kill; wait for the room to be gone so a late
    # checkpoint cannot land between the snapshots below.
    case CrdtRegistry.lookup(n.id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        CrdtRegistry.terminate_room(n.id)
        assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    end

    before = persisted(user, n.id)
    jobs = all_enqueued()

    assert {:ok, %{rivals: [_]}} = LineageAudit.run(user_id: user.id)

    assert persisted(user, n.id) == before
    assert CrdtRegistry.lookup(n.id) == nil
    assert all_enqueued() == jobs
  end

  # What a write would move: the row's updated_at and crdt_head, the stored
  # snapshot (a flatten rewrites ciphertext + nonce without touching
  # updated_at), and the log.
  defp persisted(user, note_id) do
    {:ok, state} =
      Repo.with_tenant(user.id, fn ->
        row =
          Repo.one!(
            from(n in Note,
              where: n.id == ^note_id,
              select: {n.updated_at, n.crdt_head, n.crdt_state_ciphertext, n.crdt_state_nonce}
            )
          )

        log = Repo.aggregate(from(l in CrdtUpdateLog, where: l.note_id == ^note_id), :count)
        {row, log}
      end)

    state
  end

  test "corrupt state is unreadable with a reason, and the run goes on", ctx do
    %{user: user, vault: vault} = ctx
    bad = note(user, vault, "C/Bad.md", "x\n")
    good = note(user, vault, "C/Good.md", "y\n")
    CrdtRegistry.terminate_room(bad.id)
    # Also break the facade: the audit must not need it.
    set_note(user, bad.id,
      crdt_state_ciphertext: :crypto.strong_rand_bytes(48),
      content_ciphertext: :crypto.strong_rand_bytes(48)
    )

    assert {:error, :decrypt} = LineageAudit.scan_note(user, vault, bad.id)

    assert {:ok,
            %{scanned: 2, unreadable_count: 1, unreadable: [%{note_id: id, reason: :decrypt}]}} =
             LineageAudit.run(user_id: user.id)

    assert id == bad.id
    assert {:ok, %{root_count: 1}} = LineageAudit.scan_note(user, vault, good.id)
  end

  test "a missing owner is unreadable, not a raise", %{user: user, vault: vault} do
    n = note(user, vault, "C/Owner.md", "x\n")
    assert {:error, :owner_missing} = LineageAudit.scan_note(nil, vault, n.id)
    assert {:error, :owner_missing} = LineageAudit.scan_note(user, nil, n.id)
  end

  test "a full run spans tenants", %{user: user, vault: vault} do
    {other, other_vault} = owner("LineageAudit2")
    mine = note(user, vault, "D/Mine.md", "a\n")
    theirs = note(other, other_vault, "D/Theirs.md", "b\n")
    rival_seed(other, other_vault, theirs.id, "b\nc\n")

    assert {:ok, %{rivals: rivals} = result} = LineageAudit.run()
    assert result.scanned >= 2
    assert theirs.id in Enum.map(rivals, & &1.note_id)
    refute mine.id in Enum.map(rivals, & &1.note_id)
  end

  test "limit and after_id resume in id order", %{user: user, vault: vault} do
    ids =
      for i <- 1..3, do: note(user, vault, "E/#{i}.md", "n#{i}\n").id

    [_, b, c] = Enum.sort(ids)

    assert {:ok, %{scanned: 2, last_id: ^b}} = LineageAudit.run(user_id: user.id, limit: 2)

    assert {:ok, %{scanned: 1, last_id: ^c}} =
             LineageAudit.run(user_id: user.id, limit: 2, after_id: b)

    assert {:ok, %{scanned: 0}} = LineageAudit.run(user_id: user.id, after_id: c)
  end

  test "a whole-fleet run that scans nothing is an error" do
    assert {:error, :scanned_nothing} = LineageAudit.run()
  end

  test "refuses where RLS would hide every row" do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")
      assert {:error, :no_maintenance_repo} = LineageAudit.run()
      Repo.rollback(:done)
    end)
  end

  test "progress lines carry counts and last_id only", %{user: user, vault: vault} do
    n = note(user, vault, "F/Zanzibar Quokka.md", "xylophone marmalade\n")
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    log =
      capture_log([level: :info], fn ->
        {result, events} =
          LogCapture.with_events(fn -> LineageAudit.run(user_id: user.id, progress_every: 1) end)

        send(self(), {:audit, result, events})
      end)

    assert_received {:audit, {:ok, %{scanned: 1}}, events}
    assert [event] = Enum.filter(events, &Map.has_key?(&1.meta, :scanned))

    assert Map.take(event.meta, [:scanned, :rivals, :suspects, :unreadable, :last_id]) ==
             %{scanned: 1, rivals: 0, suspects: 0, unreadable: 0, last_id: n.id}

    for key <- [:note_id, :path, :title, :content], do: refute(Map.has_key?(event.meta, key))
    assert log =~ "lineage audit progress"
    assert log =~ n.id

    for secret <- ["Zanzibar", "Quokka", "xylophone", "marmalade"] do
      refute log =~ secret
      refute inspect(events) =~ secret
    end
  end

  test "run/1 reports only rival notes, ids and counts only", %{user: user, vault: vault} do
    clean = note(user, vault, "B/Clean.md", "fine\n")
    doubled = note(user, vault, "B/Doubled.md", "old body\n")
    rival_seed(user, vault, doubled.id, "old body\nnew line\n")

    assert {:ok,
            %{
              scanned: 2,
              unreadable: [],
              unreadable_count: 0,
              rivals: [finding],
              suspects: []
            }} = LineageAudit.run(user_id: user.id)

    assert finding.note_id == doubled.id

    assert Map.keys(finding) |> Enum.sort() ==
             [:lineage_lengths, :live_root_count, :note_id, :root_client_count, :root_count]

    refute finding.note_id == clean.id
  end
end
