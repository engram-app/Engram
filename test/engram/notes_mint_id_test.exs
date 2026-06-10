defmodule Engram.NotesMintIdTest do
  # Phase B4: Unit-level coverage for the `Engram.Notes.mint_id/0` helper.
  # Lives in its own file (not `notes_test.exs`) so it doesn't run the
  # module-level DB setup block — that setup depends on schemas whose UUID
  # PK columns land in Phase C's `structure.sql` regen. Once Phase C lands
  # and Phase I sweeps factories, an end-to-end variant that round-trips
  # through `Engram.Notes.upsert_note/3` will assert `note.id == minted_id`
  # after insert.
  use ExUnit.Case, async: true

  alias Engram.Notes

  test "mint_id/0 returns a uuid in 36-char string form" do
    id = Notes.mint_id()
    assert is_binary(id)
    assert byte_size(id) == 36
    assert {:ok, _} = Ecto.UUID.cast(id)
  end

  test "successive mint_id/0 calls sort lexically by mint time" do
    a = Notes.mint_id()
    Process.sleep(2)
    b = Notes.mint_id()
    assert a < b
  end
end
