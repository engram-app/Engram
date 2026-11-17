defmodule Engram.Folders.WriteStopTimingTest do
  # S5 (Engram#2523) at staging size: a 1,000-note folder, in the shape prod
  # rows have today (named by the S2 ledger, `name_key` never written). The
  # first rename fills the keys (one UPDATE of the unkeyed rows), every later
  # one writes no note row at all. The cascade is timed on the same folder for
  # comparison. Prints one line of timings (the PR's numbers).
  use Engram.DataCase, async: false

  alias Engram.{Crypto, Fixtures, Folders, Notes, QueryRecorder, Repo, ServiceConfig}
  alias Engram.Folders.Rows
  alias Engram.Workers.BackfillNoteNames

  @n 1_000
  @moduletag timeout: 300_000

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    ServiceConfig.put_override(:folder_ops, true)

    {:ok, _} = Repo.with_tenant(user.id, fn -> Rows.ensure_all(user, vault.id, ["Big"]) end)
    ids = Fixtures.insert_notes!(user, vault, for(i <- 1..@n, do: %{path: "Big/n#{i}.md"}))

    for chunk <- Enum.chunk_every(ids, 200),
        do: BackfillNoteNames.heal_window(:notes, chunk, %{repo: Repo, user_id: user.id})

    # Prod's shape: the R9 backfill set every folder reference, and no
    # writer has touched the rows since 20261113100000 (no `name_key`).
    big = Repo.with_tenant!(user.id, fn -> Rows.ids_by_path(user, vault.id, ["Big"]) end)["Big"]
    v_id = Ecto.UUID.dump!(vault.id)

    Repo.query!("UPDATE notes SET folder_ref_id = $2 WHERE vault_id = $1", [
      v_id,
      Ecto.UUID.dump!(big)
    ])

    Repo.query!("UPDATE notes SET name_key = NULL WHERE vault_id = $1", [v_id])

    %{user: user, vault: vault}
  end

  defp timed(fun) do
    {us, result} = :timer.tc(fun)
    {div(us, 1000), result}
  end

  defp mine(queries), do: Enum.filter(queries, &(&1.pid == self()))

  defp note_writes(queries),
    do: queries |> mine() |> Enum.count(&(&1.sql =~ ~r/^\s*(UPDATE|INSERT INTO)\s+"?notes"?\b/i))

  test "a 1,000-note folder: keys once, then one folder row", %{user: u, vault: v} do
    {first_ms, {:ok, %{notes: @n}}} = timed(fn -> Folders.rename(u, v, "Big", "Big2") end)

    {{second_ms, {:ok, %{notes: @n}}}, queries} =
      QueryRecorder.record(fn -> timed(fn -> Folders.rename(u, v, "Big2", "Big3") end) end)

    assert note_writes(queries) == 0
    assert {:ok, %{path: "Big3/n1.md"}} = Notes.get_note(u, v, "Big3/n1.md")
    assert {:ok, %{path: "Big3/n1000.md"}} = Notes.get_note(u, v, "Big3/n1000.md")
    assert {:error, :not_found} = Notes.get_note(u, v, "Big/n1.md")

    ServiceConfig.put_override(:folder_write_stop, false)
    {cascade_ms, {:ok, %{notes: @n}}} = timed(fn -> Folders.rename(u, v, "Big3", "Big4") end)
    assert {:ok, %{path: "Big4/n500.md"}} = Notes.get_note(u, v, "Big4/n500.md")

    IO.puts(
      "\nS5 timing, #{@n} notes: first (fills keys) #{first_ms} ms, " <>
        "then #{second_ms} ms (#{length(mine(queries))} statements, 0 note writes); " <>
        "cascade #{cascade_ms} ms"
    )
  end
end
