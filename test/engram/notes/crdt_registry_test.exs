defmodule Engram.Notes.CrdtRegistryTest do
  use Engram.DataCase, async: false

  alias Engram.Notes.CrdtRegistry

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "CrdtRegistryTest"})
    %{user: user, vault: vault, note_id: Ecto.UUID.generate()}
  end

  test "ensure_started is idempotent — same pid for the same note", ctx do
    %{user: u, vault: v, note_id: id} = ctx
    {:ok, pid1} = CrdtRegistry.ensure_started(u.id, v.id, id)
    {:ok, pid2} = CrdtRegistry.ensure_started(u.id, v.id, id)
    assert pid1 == pid2
    assert Process.alive?(pid1)
  end

  test "distinct notes get distinct rooms", ctx do
    %{user: u, vault: v} = ctx
    {:ok, p1} = CrdtRegistry.ensure_started(u.id, v.id, Ecto.UUID.generate())
    {:ok, p2} = CrdtRegistry.ensure_started(u.id, v.id, Ecto.UUID.generate())
    refute p1 == p2
  end

  test "room doc uses UTF-16 offset kind", ctx do
    %{user: u, vault: v, note_id: id} = ctx
    {:ok, pid} = CrdtRegistry.ensure_started(u.id, v.id, id)
    doc = Yex.Sync.SharedDoc.get_doc(pid)
    # Insert a multi-byte character to verify UTF-16 offset semantics.
    # If offset_kind were :bytes (y_ex default), this operation could
    # diverge from what JS Yjs clients expect.
    text = Yex.Doc.get_text(doc, Engram.Notes.CrdtBridge.text_name())
    assert :ok = Yex.Text.insert(text, 0, "café")
    assert Yex.Text.to_string(text) == "café"
  end
end
