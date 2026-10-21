defmodule Engram.Repo.CiphertextStorageTest do
  # Guard: the compressed-then-encrypted ciphertext columns are stored
  # EXTERNAL (no TOAST compression attempt), and the columns that are NOT
  # compressed before encryption are left at the default.
  use Engram.DataCase, async: true

  @external [
    {"notes", "content_ciphertext"},
    {"notes", "crdt_state_ciphertext"},
    {"note_revisions", "pending_ciphertext"},
    {"vault_index_states", "state_ciphertext"},
    {"vault_index_update_log", "update_ciphertext"}
  ]

  defp storage(table, column) do
    %{rows: [[s]]} =
      Repo.query!(
        """
        SELECT a.attstorage FROM pg_attribute a
        WHERE a.attrelid = $1::text::regclass AND a.attname = $2
        """,
        [table, column]
      )

    s
  end

  test "zstd-before-encrypt ciphertext columns are STORAGE EXTERNAL" do
    for {t, c} <- @external, do: assert(storage(t, c) == "e", "#{t}.#{c}")
  end

  test "crdt_update_log.update_ciphertext keeps the default" do
    assert storage("crdt_update_log", "update_ciphertext") == "x"
  end
end
