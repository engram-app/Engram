defmodule Engram.Folders.BatchFolderReadsTest do
  # A restore or a batch move of N notes reads each DISTINCT destination folder
  # once, not once per note: the [folders] query count must not grow with N.
  use Engram.DataCase, async: false

  alias Engram.{Folders, Notes, QueryRecorder}

  @n 60

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp put_note(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    note
  end

  defp folder_queries(queries),
    do: Enum.filter(queries, &(&1.pid == self() and &1.source == "folders"))

  defp assert_bounded(queries) do
    mine = folder_queries(queries)

    assert length(mine) < 30,
           "folders queries grew with the batch (#{length(mine)}):\n" <>
             QueryRecorder.format(Enum.take(mine, 12))
  end

  test "restoring N notes across 3 folders reads folder rows a bounded number of times", %{
    user: u,
    vault: v
  } do
    for i <- 1..@n, do: put_note(u, v, "R#{rem(i, 3)}/n#{i}.md")
    op = Ecto.UUID.generate()

    for f <- ~w(R0 R1 R2),
        do: assert({:ok, _} = Folders.delete(u, v, f, recursive: true, op_id: op))

    {{:ok, %{notes: restored}}, queries} =
      QueryRecorder.record(fn -> Folders.restore_op(u, v, op) end)

    assert restored == @n
    assert_bounded(queries)
  end

  test "batch-moving N notes reads folder rows a bounded number of times", %{user: u, vault: v} do
    ids = for i <- 1..@n, do: put_note(u, v, "S#{rem(i, 3)}/n#{i}.md").id

    {{:ok, %{moved: moved}}, queries} =
      QueryRecorder.record(fn -> Notes.batch_move_notes(u, v, ids, {:path, "Dest"}) end)

    assert moved == @n
    assert_bounded(queries)
  end
end
