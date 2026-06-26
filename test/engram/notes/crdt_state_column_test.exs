defmodule Engram.Notes.CrdtStateColumnTest do
  use Engram.DataCase, async: true

  alias Engram.Repo

  test "notes table has nullable crdt_state_ciphertext and crdt_state_nonce bytea columns" do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name, data_type, is_nullable
        FROM information_schema.columns
        WHERE table_name = 'notes'
          AND column_name IN ('crdt_state_ciphertext', 'crdt_state_nonce')
        ORDER BY column_name
        """,
        []
      )

    assert rows == [
             ["crdt_state_ciphertext", "bytea", "YES"],
             ["crdt_state_nonce", "bytea", "YES"]
           ]
  end
end
