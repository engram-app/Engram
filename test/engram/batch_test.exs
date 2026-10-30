defmodule Engram.BatchTest do
  use ExUnit.Case, async: true

  alias Engram.Batch

  # The values are the measured / incident-tested ones; changing one is a
  # decision that needs a new measurement, so a change must be deliberate.
  test "sizes keep their measured values" do
    assert Batch.insert_rows() == 2_000
    assert Batch.release_index_entries() == 2_000
    assert Batch.reconcile_page() == 1_000
    assert Batch.folder_delete() == 500
  end

  test "the folder-delete chunk is the shared size unless a test lowers it" do
    assert Engram.Attachments.delete_chunk_size() == Batch.folder_delete()
  end
end
