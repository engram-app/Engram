defmodule Engram.Workers.ReleaseIndexEntriesTest do
  use ExUnit.Case, async: true

  alias Engram.Workers.ReleaseIndexEntries

  defp ids(n), do: for(_ <- 1..n, do: Ecto.UUID.generate())

  # ONE job per call, whatever the size: perform/1 works through its ids a
  # chunk at a time and hands the rest to a successor only past its time
  # budget, so a release chain never occupies more than one queue slot. That
  # is exercised against a real index in ProjectVaultIndexTest.
  describe "new_for/3" do
    test "no ids, no job" do
      assert ReleaseIndexEntries.new_for("u", "v", []) == :skip
    end

    test "any number of ids is ONE job carrying all of them, in order" do
      all = ids(ReleaseIndexEntries.chunk_size() * 2 + 7)
      job = ReleaseIndexEntries.new_for("u", "v", all)

      assert %Ecto.Changeset{} = job
      assert job.changes.args == %{user_id: "u", vault_id: "v", note_ids: all}
    end
  end
end
