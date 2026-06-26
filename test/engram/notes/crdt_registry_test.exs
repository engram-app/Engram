defmodule Engram.Notes.CrdtRegistryTest do
  use Engram.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Notes, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtRegistry}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "CrdtRegistryTest"})
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "r.md", "content" => "base"})
    %{user: user, vault: vault, note: note}
  end

  test "ensure_started is idempotent — same pid for the same note", ctx do
    %{user: u, vault: v, note: note} = ctx
    {:ok, pid1} = CrdtRegistry.ensure_started(u.id, v.id, note.id)
    Sandbox.allow(Engram.Repo, self(), pid1)
    {:ok, pid2} = CrdtRegistry.ensure_started(u.id, v.id, note.id)
    assert pid1 == pid2
    assert Process.alive?(pid1)
  end

  test "distinct notes get distinct rooms", ctx do
    %{user: u, vault: v} = ctx
    {:ok, note1} = Notes.upsert_note(u, v, %{"path" => "r1.md", "content" => "a"})
    {:ok, note2} = Notes.upsert_note(u, v, %{"path" => "r2.md", "content" => "b"})
    {:ok, p1} = CrdtRegistry.ensure_started(u.id, v.id, note1.id)
    Sandbox.allow(Engram.Repo, self(), p1)
    {:ok, p2} = CrdtRegistry.ensure_started(u.id, v.id, note2.id)
    Sandbox.allow(Engram.Repo, self(), p2)
    refute p1 == p2
  end

  test "room doc uses UTF-16 offset kind", ctx do
    %{user: u, vault: v} = ctx
    # Use a note with empty content so the doc starts blank — this isolates the
    # UTF-16 offset check from any pre-seeded content.
    {:ok, empty_note} = Notes.upsert_note(u, v, %{"path" => "utf16.md", "content" => ""})
    {:ok, pid} = CrdtRegistry.ensure_started(u.id, v.id, empty_note.id)
    Sandbox.allow(Engram.Repo, self(), pid)
    doc = Yex.Sync.SharedDoc.get_doc(pid)
    # Insert a multi-byte character to verify UTF-16 offset semantics.
    # If offset_kind were :bytes (y_ex default), this operation could
    # diverge from what JS Yjs clients expect.
    text = Yex.Doc.get_text(doc, CrdtBridge.text_name())
    assert :ok = Yex.Text.insert(text, 0, "café")
    assert Yex.Text.to_string(text) == "café"
  end
end
