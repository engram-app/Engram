defmodule Engram.DeadColumnsTest do
  # Columns nothing needs, phase 1 of 2 (AGENTS.md "Database changes",
  # rule 3): the code stops reading and writing them here, and a later
  # release drops them once no running node selects them.
  #
  #   * note_revisions.actor_user_id: never written.
  #   * note_revisions.char_count: written, never read.
  use ExUnit.Case, async: true

  test "the schemas no longer map the dead columns" do
    fields = Engram.Notes.Revision.__schema__(:fields)
    refute :actor_user_id in fields
    refute :char_count in fields
  end
end
