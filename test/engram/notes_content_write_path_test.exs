defmodule Engram.NotesContentWritePathTest do
  # A content-only write used to re-encrypt the unchanged path and folder
  # with fresh nonces. That changed path_nonce and link_keys_stamp, columns
  # in index keys and predicates (notes_link_keys_stale_index), so no content
  # write could be a HOT update, and it was AES work and WAL for nothing. The
  # REST update also fenced on the whole crdt_state ciphertext, sending
  # (and making Postgres de-TOAST) the state on every edit just to compare
  # it; the nonce identifies the same version, since every write of the state
  # encrypts it under a fresh one.
  use Engram.DataCase, async: true

  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.QueryRecorder

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "Dir/A.md", "content" => "a"}, actor: "api")

    %{user: user, vault: vault, note: note}
  end

  defp row(note), do: Repo.get!(Note, note.id, skip_tenant_check: true)

  test "a REST content update keeps the stored path and folder ciphertext", ctx do
    %{user: u, vault: v, note: n} = ctx
    before = row(n)

    {:ok, _} =
      Notes.upsert_note(u, v, %{"path" => "Dir/A.md", "content" => "changed"}, actor: "api")

    after_ = row(n)

    assert after_.content_hash != before.content_hash
    assert after_.path_nonce == before.path_nonce
    assert after_.path_ciphertext == before.path_ciphertext
    assert after_.folder_nonce == before.folder_nonce
    assert after_.link_keys_stamp == before.link_keys_stamp
  end

  test "the REST update fences on the state nonce, not the state bytes", ctx do
    %{user: u, vault: v} = ctx
    # A checkpointed note, so the row carries a CRDT state to fence on.
    {:ok, _} = Notes.upsert_note(u, v, %{"path" => "Dir/A.md", "content" => "b"}, actor: "api")

    {_, queries} =
      QueryRecorder.record(fn ->
        Notes.upsert_note(u, v, %{"path" => "Dir/A.md", "content" => "c"}, actor: "api")
      end)

    # This process's statements only: the recorder sees async siblings' too.
    me = self()
    [update] = for %{sql: "UPDATE \"notes\" SET" <> _ = sql, pid: ^me} <- queries, do: sql
    [_, where] = String.split(update, " WHERE ", parts: 2)
    assert where =~ ~s("crdt_state_nonce" = $)
    refute where =~ "crdt_state_ciphertext"
  end

  test "a rename still rewrites the path", ctx do
    %{user: u, vault: v, note: n} = ctx
    before = row(n)
    {:ok, _} = Notes.rename_note(u, v, "Dir/A.md", "Dir/B.md")
    assert row(n).path_nonce != before.path_nonce
  end
end
