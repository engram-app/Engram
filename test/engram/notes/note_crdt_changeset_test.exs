defmodule Engram.Notes.NoteCrdtChangesetTest do
  use ExUnit.Case, async: true

  alias Engram.Notes.Note

  test "changeset casts crdt_state_ciphertext and crdt_state_nonce" do
    cs =
      Note.changeset(%Note{}, %{
        crdt_state_ciphertext: <<1, 2, 3>>,
        crdt_state_nonce: <<4, 5, 6>>
      })

    assert Ecto.Changeset.get_change(cs, :crdt_state_ciphertext) == <<1, 2, 3>>
    assert Ecto.Changeset.get_change(cs, :crdt_state_nonce) == <<4, 5, 6>>
  end
end
