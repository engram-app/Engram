defmodule Engram.Maintenance.ChangeFeedTest do
  # The "written since the last run" read for the hourly sweeps: the sync
  # change sequence, index reads only, no index on a column a save writes.
  use Engram.DataCase, async: false

  alias Engram.Maintenance.ChangeFeed
  alias Engram.Notes
  alias Engram.QueryPlan

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Feed", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  # The feed, committed (the consumer succeeded).
  defp changed(name, per_vault \\ 1_000) do
    {rows, commit} = ChangeFeed.changed(name, per_vault)
    :ok = commit.()
    rows
  end

  defp write(u, v, path),
    do: {:ok, _} = Notes.upsert_note(u, v, %{"path" => path, "content" => path}, actor: "api")

  test "first call starts at the current seq; later calls return each write once", %{
    user: u,
    vault: v
  } do
    {:ok, old} = write(u, v, "old.md")
    assert changed("t") == []

    {:ok, a} = write(u, v, "a.md")
    {:ok, b} = write(u, v, "b.md")
    ids = changed("t") |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == Enum.sort([a.id, b.id])
    refute old.id in ids
    assert changed("t") == []
  end

  test "a vault with more than a page continues next call, and deleted notes are skipped", %{
    user: u,
    vault: v
  } do
    assert changed("p", 1) == []
    {:ok, a} = write(u, v, "a.md")
    {:ok, b} = write(u, v, "b.md")
    Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [Ecto.UUID.dump!(b.id)])

    assert [%{id: id}] = changed("p", 1)
    assert id == a.id
    assert changed("p", 1) == []
  end

  # Red on daa914e6d: the cursor moved before the consumer ran, so a failed
  # run lost its rows.
  test "a consumer that fails before committing reads the same rows next run", %{
    user: u,
    vault: v
  } do
    assert changed("c") == []
    {:ok, a} = write(u, v, "a.md")

    {rows, _commit} = ChangeFeed.changed("c")
    assert Enum.map(rows, & &1.id) == [a.id]
    assert Enum.map(changed("c"), & &1.id) == [a.id]
    assert changed("c") == []
  end

  # Red on daa914e6d: the cursor stayed at the last note seq, so a vault
  # whose last change was not a note was walked on every run.
  test "a vault whose last change was not a note is not walked again", %{vault: v} do
    assert changed("s") == []
    _ = Engram.Vaults.next_seq!(v.id)
    assert changed("s") == []

    %{rows: [[seq]]} =
      Repo.query!("SELECT change_seq FROM vaults WHERE id = $1", [Ecto.UUID.dump!(v.id)])

    assert [^seq, "ffffffff-ffff-ffff-ffff-ffffffffffff"] =
             Engram.Maintenance.Cursor.get("s")[v.id]
  end

  # Red on 5be4a3373's `updated_at >= $1` read: notes has no index on
  # updated_at alone, so it walked every row. The feed is a range of the sync
  # index per moved vault.
  test "the notes read is an index range, never a scan of notes" do
    plan = QueryPlan.generic_plan(ChangeFeed.notes_sql(), analyze: ["notes"], fresh: true)
    # Which vault_id index serves it depends on statistics (on a tiny test
    # table any of them); the claim is that one does.
    refute plan =~ "Seq Scan on notes", plan
    assert plan =~ ~r/Index (Only )?Scan using \w+ on notes n/, plan
  end
end
