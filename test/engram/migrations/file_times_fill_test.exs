defmodule Engram.Migrations.FileTimesFillTest do
  @moduledoc """
  Migration 20261117160000 (R25 contract step (b)) fills the `*_at` twins
  still NULL over a double, with `Engram.FileTime.normalize/1`'s value in
  SQL, and never touches a set twin. Run as `engram_app` (RLS enforced):
  the suite's superuser would pass with an unscoped query too.
  """
  use Engram.DataCase, async: false

  alias Engram.Attachments
  alias Engram.FileTime
  alias Engram.FileTimeFixtures
  alias Engram.Notes

  @mod "Elixir.Engram.Repo.Migrations.FileTimesFillMigrate"

  setup_all do
    Code.require_file("priv/repo/migrations/20261117160000_file_times_fill_migrate.exs")
    :ok
  end

  setup do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp note!(ctx, path) do
    {:ok, n} =
      Notes.upsert_note(
        ctx.user,
        ctx.vault,
        %{"path" => path, "content" => "x\n", "mtime" => 1.0},
        actor: "api"
      )

    n.id
  end

  # What a release before step (b) left: a double and the given twin.
  defp legacy!(table, id, sets),
    do: Repo.query!("UPDATE #{table} SET #{sets} WHERE id = $1", [Ecto.UUID.dump!(id)])

  defp twins(table, id, cols) do
    %{rows: [row]} =
      Repo.query!("SELECT #{Enum.join(cols, ", ")} FROM #{table} WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    row
  end

  defp fill!(opts \\ []) do
    Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")

    try do
      String.to_existing_atom(@mod).fill(Repo, opts)
    after
      Repo.query!("SET LOCAL SESSION AUTHORIZATION DEFAULT")
    end
  end

  test "fills NULL twins as FileTime does: seconds, milliseconds, 0, desktop digits", ctx do
    s = note!(ctx, "s.md")
    ms = note!(ctx, "ms.md")
    legacy!("notes", s, "mtime = 1776072500.928, mtime_at = NULL, ctime = 0, ctime_at = NULL")
    legacy!("notes", ms, "mtime = 1776072500928.0, mtime_at = NULL")

    desktop =
      for {{t, _}, i} <- Enum.with_index(FileTimeFixtures.prod_desktop_times()) do
        id = note!(ctx, "d#{i}.md")
        legacy!("notes", id, "mtime = #{Float.to_string(t)}, mtime_at = NULL")
        {id, t}
      end

    {:ok, att} =
      Attachments.upsert_attachment(ctx.user, ctx.vault, %{
        "path" => "z.png",
        :content => "png",
        "mtime" => 1.0
      })

    legacy!("attachments", att.id, "mtime = 0, mtime_at = NULL")

    assert :ok = fill!()

    assert twins("notes", s, [:mtime_at, :ctime_at]) == [
             ~U[2026-04-13 09:28:20.928000Z],
             ~U[1970-01-01 00:00:00.000000Z]
           ]

    assert twins("notes", ms, [:mtime_at]) == [~U[2026-04-13 09:28:20.928000Z]]
    assert twins("attachments", att.id, [:mtime_at]) == [~U[1970-01-01 00:00:00.000000Z]]

    # Shortest round-trip decimal, not the exact binary value: within 1 us.
    for {id, t} <- desktop do
      [at] = twins("notes", id, [:mtime_at])
      assert FileTime.twin?(at, t), inspect({t, at})
    end
  end

  test "CONTROL: a set twin is never touched, a NULL double stays NULL", ctx do
    kept = note!(ctx, "kept.md")
    none = note!(ctx, "none.md")
    legacy!("notes", kept, "mtime = 1000000000.0")
    legacy!("notes", none, "mtime = NULL, mtime_at = NULL")
    before = twins("notes", kept, [:mtime_at])

    assert :ok = fill!()

    assert twins("notes", kept, [:mtime_at]) == before
    assert twins("notes", none, [:mtime_at]) == [nil]
  end

  # A migrator that sees every tenant (here the suite's superuser) takes
  # the set-based path: one UPDATE per table that needs any.
  test "the all-tenants path fills too", ctx do
    s = note!(ctx, "s.md")
    legacy!("notes", s, "mtime = 1776072500.928, mtime_at = NULL")

    assert :ok = String.to_existing_atom(@mod).fill(Repo)
    assert twins("notes", s, [:mtime_at]) == [~U[2026-04-13 09:28:20.928000Z]]
  end

  # Review of #2626: every write is a window in its own transaction, so a
  # cancel keeps the windows done. One-row windows walk both paths.
  test "fills in windows on both paths, committing each", ctx do
    ids = for i <- 1..3, do: note!(ctx, "w#{i}.md")
    for id <- ids, do: legacy!("notes", id, "mtime = 1776072500.928, mtime_at = NULL")

    assert :ok = fill!(window: 1)

    for id <- ids,
        do: assert(twins("notes", id, [:mtime_at]) == [~U[2026-04-13 09:28:20.928000Z]])

    for id <- ids, do: legacy!("notes", id, "mtime_at = NULL")
    assert :ok = String.to_existing_atom(@mod).fill(Repo, window: 1)

    for id <- ids,
        do: assert(twins("notes", id, [:mtime_at]) == [~U[2026-04-13 09:28:20.928000Z]])
  end

  # Review of #2626: an out-of-range double normalizes to NULL, so its row
  # still matches the fill. The tenant walk must step past it, not select
  # it again forever (window 1: one such row is enough).
  test "the tenant walk steps past a row it cannot fill", ctx do
    bad = note!(ctx, "bad.md")
    ok = note!(ctx, "ok.md")
    legacy!("notes", bad, "mtime = 1.0e19, mtime_at = NULL")
    legacy!("notes", ok, "mtime = 1776072500.928, mtime_at = NULL")

    assert :ok = fill!(window: 1)
    assert twins("notes", bad, [:mtime_at]) == [nil]
    assert twins("notes", ok, [:mtime_at]) == [~U[2026-04-13 09:28:20.928000Z]]
  end

  # A window locked out is retried twice, the user once more after the
  # others, and only then does the run raise (not recorded).
  test "lock contention: retried, then the run raises", ctx do
    id = note!(ctx, "locked.md")
    legacy!("notes", id, "mtime = 1776072500.928, mtime_at = NULL")
    calls = :counters.new(1, [])

    locked = fn ->
      :counters.add(calls, 1, 1)
      raise %Postgrex.Error{postgres: %{code: :lock_not_available}}
    end

    assert_raise RuntimeError, ~r/locked out after retries/, fn ->
      fill!(before_window: locked)
    end

    assert :counters.get(calls, 1) == 6
    assert twins("notes", id, [:mtime_at]) == [nil]
  end

  test "out of range is NULL" do
    for x <- ["1.0e19", "-1.0e15"] do
      %{rows: [[at]]} =
        Repo.query!("SELECT #{normalized_sql("x")} FROM (SELECT #{x}::float8 AS x) v")

      assert at == nil, x
    end
  end

  # The migration's expression, through a one-row fill on a scratch note.
  defp normalized_sql(x) do
    String.to_existing_atom(@mod).normalized_sql(x)
  end
end
