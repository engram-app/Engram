defmodule Engram.Workers.ReleaseIndexEntriesTest do
  use ExUnit.Case, async: true

  alias Engram.Workers.ReleaseIndexEntries

  defp ids(n), do: for(_ <- 1..n, do: Ecto.UUID.generate())
  defp sizes(changesets), do: Enum.map(changesets, &length(&1.changes.args.note_ids))

  describe "new_for/3 chunks at chunk_size/0" do
    setup do: %{chunk: Engram.Workers.ReleaseIndexEntries.chunk_size()}

    test "no ids, no jobs" do
      assert ReleaseIndexEntries.new_for("u", "v", []) == []
    end

    test "exactly one chunk of ids is one job", %{chunk: chunk} do
      assert sizes(ReleaseIndexEntries.new_for("u", "v", ids(chunk))) == [chunk]
    end

    test "one id over a chunk is two jobs", %{chunk: chunk} do
      assert sizes(ReleaseIndexEntries.new_for("u", "v", ids(chunk + 1))) == [chunk, 1]
    end

    test "every id lands in exactly one job, in order", %{chunk: chunk} do
      all = ids(chunk * 2 + 7)
      jobs = ReleaseIndexEntries.new_for("u", "v", all)
      assert Enum.flat_map(jobs, & &1.changes.args.note_ids) == all

      assert Enum.all?(
               jobs,
               &(&1.changes.args.user_id == "u" and &1.changes.args.vault_id == "v")
             )
    end
  end
end
