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

  test "re-push after a delete resurrects instead of short-circuiting", %{
    user: user,
    vault: vault
  } do
    {:ok, n1} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# Same"})
    :ok = Notes.delete_note(user, vault, "a.md")

    {:ok, n2} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# Same"})

    assert is_nil(n2.deleted_at)
    refute n2.id == n1.id
  end
end
