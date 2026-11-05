defmodule Engram.Repo.NoteFilterIndexMigrationsTest do
  @moduledoc """
  The note filter's CONCURRENTLY index migrations heal themselves: a build
  that failed or timed out leaves an INVALID index, and the next boot's run
  must drop it and rebuild it, while leaving a valid index alone. No
  operator step.

  Runs the real migration modules outside the sandbox (a CONCURRENTLY build
  cannot run in a transaction block) under a throwaway version, removed
  after.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Repo

  @version 19_700_101_000_001

  @migrations [
    {"20261105150100_index_notes_effective_dates_expand.exs",
     ~w(notes_eff_updated_live notes_eff_created_live)},
    {"20261105150200_index_notes_folder_live_expand.exs", ~w(notes_folder_live)}
  ]

  defp load(file) do
    [{mod, _}] = Code.compile_file(Path.join("priv/repo/migrations", file))
    mod
  end

  defp index(name) do
    %{rows: [[oid, valid?]]} =
      Repo.query!(
        "SELECT i.indexrelid::bigint, i.indisvalid FROM pg_index i " <>
          "JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = $1",
        [name]
      )

    {oid, valid?}
  end

  defp run!(mod) do
    try do
      Ecto.Migrator.up(Repo, @version, mod, log: false)
    after
      Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@version])
    end
  end

  for {file, [broken | kept]} <- @migrations do
    test "#{file}: an INVALID leftover is rebuilt, a valid index is kept" do
      Sandbox.unboxed_run(Repo, fn ->
        mod = load(unquote(file))
        before = Map.new(unquote([broken | kept]), &{&1, index(&1)})

        # What a failed or timed-out CONCURRENTLY build leaves behind.
        Repo.query!(
          "UPDATE pg_index SET indisvalid = false WHERE indexrelid = to_regclass($1::text)",
          [unquote(broken)]
        )

        assert {_, false} = index(unquote(broken))

        run!(mod)

        {oid, valid?} = index(unquote(broken))
        assert valid?
        refute oid == elem(before[unquote(broken)], 0)

        for name <- unquote(kept), do: assert(index(name) == before[name])

        # A clean rerun rebuilds nothing.
        snapshot = Map.new(unquote([broken | kept]), &{&1, index(&1)})
        run!(mod)
        assert Map.new(unquote([broken | kept]), &{&1, index(&1)}) == snapshot
      end)
    end
  end
end
