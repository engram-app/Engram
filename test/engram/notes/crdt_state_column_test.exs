defmodule Engram.Notes.CrdtStateColumnTest do
  use Engram.DataCase, async: true

  alias Engram.Repo

  # R8(e): the body ciphertexts live in `note_bodies` only; `notes` keeps
  # the nonces for the write fences.
  test "notes keeps the nullable body nonces and no body ciphertext columns" do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name, data_type, is_nullable
        FROM information_schema.columns
        WHERE table_name = 'notes'
          AND column_name IN ('content_ciphertext', 'content_nonce',
                              'crdt_state_ciphertext', 'crdt_state_nonce')
        ORDER BY column_name
        """,
        []
      )

    assert rows == [
             ["content_nonce", "bytea", "YES"],
             ["crdt_state_nonce", "bytea", "YES"]
           ]
  end
end
