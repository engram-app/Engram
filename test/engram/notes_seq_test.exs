defmodule Engram.NotesSeqTest do
  use Engram.DataCase, async: true

  alias Engram.{Notes, Vaults}

  setup do
    user = insert_user()
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  defp note_seq(user, vault, id) do
    {:ok, n} = Notes.get_note_by_id(user, vault, id)
    n.seq
  end

  test "upsert_note stamps a monotonic seq on insert", %{user: user, vault: vault} do
    {:ok, n1} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A"})
    {:ok, n2} = Notes.upsert_note(user, vault, %{"path" => "b.md", "content" => "B"})
    s1 = note_seq(user, vault, n1.id)
    s2 = note_seq(user, vault, n2.id)
    assert is_integer(s1) and is_integer(s2)
    assert s2 > s1
  end

  test "upsert_note advances seq on update", %{user: user, vault: vault} do
    {:ok, n1} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A"})
    s_insert = note_seq(user, vault, n1.id)
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A2"})
    s_update = note_seq(user, vault, n1.id)
    assert s_update > s_insert
  end
end
