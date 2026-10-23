defmodule Engram.Notes.LineageAuditTest do
  use Engram.DataCase, async: false

  import ExUnit.CaptureLog

  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Notes
  alias Engram.Notes.{CrdtBridge, CrdtRegistry, CrdtTransport, CrdtUpdateLog, LineageAudit, Note}
  alias Engram.Repo

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

  test "an edited note is one lineage", %{user: user, vault: vault} do
    n = note(user, vault, "A/Clean.md", "first body line.\n")
    edit(user, vault, n.id, "first body line.\nsecond line.\n")

    assert {:ok, %{note_id: id, root_client_count: 1}} = LineageAudit.scan_note(user, vault, n.id)
    assert id == n.id
  end

  test "a fresh-device seed is two lineages", %{user: user, vault: vault} do
    n = note(user, vault, "A/Doubled.md", "first body line.\n")
    rival_seed(user, vault, n.id, "first body line.\nsecond line.\n")

    assert {:ok, %{root_client_count: 2, root_count: 2, lineage_lengths: lengths}} =
             LineageAudit.scan_note(user, vault, n.id)

    assert length(lengths) == 2
  end

  test "a doubled note whose rival copy was deleted is one lineage", %{user: user, vault: vault} do
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

    assert {:ok, %{root_client_count: 1, root_count: 1}} =
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

  test "progress lines carry counts only", %{user: user, vault: vault} do
    n = note(user, vault, "F/Secret title.md", "secret body\n")
    log = capture_log(fn -> LineageAudit.run(user_id: user.id) end)
    refute log =~ "secret"
    refute log =~ "Secret"
    assert {:ok, %{root_count: 1}} = LineageAudit.scan_note(user, vault, n.id)
  end

  test "run/1 reports only rival notes, ids and counts only", %{user: user, vault: vault} do
    clean = note(user, vault, "B/Clean.md", "fine\n")
    doubled = note(user, vault, "B/Doubled.md", "old body\n")
    rival_seed(user, vault, doubled.id, "old body\nnew line\n")

    assert {:ok, %{scanned: 2, unreadable: [], unreadable_count: 0, rivals: [finding]}} =
             LineageAudit.run(user_id: user.id)

    assert finding.note_id == doubled.id

    assert Map.keys(finding) |> Enum.sort() ==
             [:lineage_lengths, :note_id, :root_client_count, :root_count]

    refute finding.note_id == clean.id
  end
end
