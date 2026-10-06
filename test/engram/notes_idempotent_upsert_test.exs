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
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  test "re-push of identical content does not bump version or seq", %{
    user: user,
    vault: vault
  } do
    {:ok, n1} =
      Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# Same"}, actor: "api")

    {:ok, n2} =
      Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# Same"}, actor: "api")

    assert n2.id == n1.id
    assert n2.version == n1.version
    assert n2.seq == n1.seq
    assert n2.content_hash == n1.content_hash
  end

  test "re-push of identical content does not broadcast note_changed", %{
    user: user,
    vault: vault
  } do
    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# Same"}, actor: "api")

    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# Same"}, actor: "api")

    refute_receive %Phoenix.Socket.Broadcast{event: "note_changed"}, 100
  end

  test "changed content still bumps version, advances seq, and broadcasts", %{
    user: user,
    vault: vault
  } do
    {:ok, n1} =
      Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# One"}, actor: "api")

    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

    {:ok, n2} =
      Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# Two"}, actor: "api")

    assert n2.version == n1.version + 1
    assert n2.seq > n1.seq
    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed"}
  end

  test "re-push after a delete is refused within the delete-wins window (delete not silently undone)",
       %{user: user, vault: vault} do
    {:ok, _n1} =
      Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# Same"}, actor: "api")

    :ok = Notes.delete_note(user, vault, "a.md")

    # Delete-wins (Todd's chosen policy): a pathless re-push at a just-deleted
    # path is refused, so a stale device cannot resurrect a note deleted
    # elsewhere — the delete is neither silently short-circuited nor undone.
    # Post-window restore + the re-minted-id boundary live in
    # Engram.NotesDeleteTombstoneTest.
    assert {:error, :recently_deleted} =
             Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# Same"},
               actor: "api"
             )
  end
end
