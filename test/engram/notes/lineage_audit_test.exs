defmodule Engram.Notes.LineageAuditTest do
  use Engram.DataCase, async: false

  alias Engram.Notes
  alias Engram.Notes.{CrdtBridge, CrdtRegistry, CrdtTransport, LineageAudit}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "LineageAudit", Ecto.UUID.generate())
    %{user: user, vault: vault}
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

    assert {:ok, %{root_client_count: 2, lineage_lengths: lengths}} =
             LineageAudit.scan_note(user, vault, n.id)

    assert length(lengths) == 2
  end

  test "run/1 reports only rival notes, ids and counts only", %{user: user, vault: vault} do
    clean = note(user, vault, "B/Clean.md", "fine\n")
    doubled = note(user, vault, "B/Doubled.md", "old body\n")
    rival_seed(user, vault, doubled.id, "old body\nnew line\n")

    assert {:ok, %{scanned: 2, unreadable: 0, rivals: [finding]}} =
             LineageAudit.run(user_id: user.id)

    assert finding.note_id == doubled.id
    assert Map.keys(finding) |> Enum.sort() == [:lineage_lengths, :note_id, :root_client_count]
    refute finding.note_id == clean.id
  end
end
