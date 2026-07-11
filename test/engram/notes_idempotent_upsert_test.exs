defmodule Engram.NotesIdempotentUpsertTest do
  @moduledoc """
  A re-push of byte-identical content (plugin retry, offline-queue replay,
  MCP re-write) must be a no-op: no version bump, no seq allocation, no
  note_changed broadcast. Without the short-circuit every idempotent re-push
  pays full CRDT merge + re-encrypt + row rewrite and fans a phantom change
  out to every connected device.
  """
  use Engram.DataCase, async: true

  alias Engram.Notes

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  test "re-push of identical content does not bump version or seq", %{
    user: user,
    vault: vault
  } do
    {:ok, n1} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# Same"})
    {:ok, n2} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# Same"})

    assert n2.id == n1.id
    assert n2.version == n1.version
    assert n2.seq == n1.seq
    assert n2.content_hash == n1.content_hash
  end

  test "re-push of identical content does not broadcast note_changed", %{
    user: user,
    vault: vault
  } do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# Same"})

    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# Same"})

    refute_receive %Phoenix.Socket.Broadcast{event: "note_changed"}, 100
  end

  test "changed content still bumps version, advances seq, and broadcasts", %{
    user: user,
    vault: vault
  } do
    {:ok, n1} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# One"})

    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

    {:ok, n2} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# Two"})

    assert n2.version == n1.version + 1
    assert n2.seq > n1.seq
    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed"}
  end

  test "batch re-push of identical content is a no-op: no version bump, no digest broadcast",
       %{user: user, vault: vault} do
    entries = [%{"path" => "a.md", "content" => "# Same"}]
    {:ok, %{results: [r1]}} = Notes.batch_upsert_notes(user, vault, entries)

    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

    {:ok, %{results: [r2]}} = Notes.batch_upsert_notes(user, vault, entries)

    assert %{status: :ok, version: v1} = r1
    assert %{status: :ok, version: ^v1} = r2
    refute_receive %Phoenix.Socket.Broadcast{event: "notes.batch"}, 100
  end

  test "batch re-push of a frontmatter note (raw != stored projection) does not broadcast a phantom digest",
       %{user: user, vault: vault} do
    # The CRDT projection re-serializes YAML frontmatter, so the stored content
    # can differ from the raw push bytes. A re-push of the SAME raw bytes then
    # misses the identical-content short-circuit (projection vs raw hash) and
    # runs the full rewrite — but the rewrite converges to the SAME projection
    # (prev_hash == content_hash), so no digest entry may be broadcast. Gating
    # the digest on the raw entry hash instead fans a phantom change to every
    # device on each idempotent re-push of such a note.
    raw = "---\ntitle:    Spaced   Out\n---\nbody\n"
    entries = [%{"path" => "fm.md", "content" => raw}]
    {:ok, _} = Notes.batch_upsert_notes(user, vault, entries)

    {:ok, stored} = Notes.get_note(user, vault, "fm.md")
    # Precondition: projection and raw genuinely diverge — otherwise this test
    # is vacuous (the identical-content test above already covers that case).
    assert stored.content != raw

    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

    {:ok, _} = Notes.batch_upsert_notes(user, vault, entries)

    refute_receive %Phoenix.Socket.Broadcast{event: "notes.batch"}, 100
  end

  test "re-push after a delete is refused within the delete-wins window (delete not silently undone)",
       %{user: user, vault: vault} do
    {:ok, _n1} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# Same"})
    :ok = Notes.delete_note(user, vault, "a.md")

    # Delete-wins (Todd's chosen policy): a pathless re-push at a just-deleted
    # path is refused, so a stale device cannot resurrect a note deleted
    # elsewhere — the delete is neither silently short-circuited nor undone.
    # Post-window restore + the re-minted-id boundary live in
    # Engram.NotesDeleteTombstoneTest.
    assert {:error, :recently_deleted} =
             Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# Same"})
  end
end
