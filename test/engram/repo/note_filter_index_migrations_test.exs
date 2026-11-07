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
    {"20261105150200_index_notes_folder_live_expand.exs", ~w(notes_folder_live)},
    {"20261106100000_index_notes_folder_ref_live_expand.exs", ~w(notes_folder_ref_live)},
    {"20261106100100_index_attachments_folder_ref_live_expand.exs",
     ~w(attachments_folder_ref_live)}
  ]

  defp load(file), do: Engram.MigrationFile.load!(file)

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
    Ecto.Migrator.up(Repo, @version, mod, log: false, dynamic_repo: Repo.get_dynamic_repo())
  after
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@version])
  end

  # `{connection_id, sql}` of every statement sent while `fun` runs (the
  # migrator runs `up/0` in its own process).
  defp statements(fun) do
    me = self()
    ref = make_ref()
    id = "migration-conn-#{inspect(ref)}"

    :telemetry.attach(
      id,
      [:engram, :repo, :query],
      fn _, _, %{query: sql, result: result}, _ ->
        with {:ok, %{connection_id: conn}} <- result, do: send(me, {ref, conn, sql})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    collect(ref, [])
  end

  defp collect(ref, acc) do
    receive do
      {^ref, conn, sql} -> collect(ref, [{conn, sql} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # With no DDL transaction each `execute` can take another pooled
  # connection (the release migrator's pool is 2): the timeout must be set
  # on the connection the build runs on, and reset there. A private 2-conn
  # pool, as in prod; the sandbox would pin one connection and hide it.
  for {file, names} <- @migrations do
    test "#{file}: the timeout, the builds and the reset share one connection" do
      {:ok, pool} =
        Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 2)

      Repo.put_dynamic_repo(pool)
      on_exit(fn -> Repo.put_dynamic_repo(Repo) end)

      begin = fn ->
        mod = load(unquote(file))

        for name <- unquote(names),
            do:
              Repo.query!(
                "UPDATE pg_index SET indisvalid = false WHERE indexrelid = to_regclass($1::text)",
                [name]
              )

        sent = statements(fn -> run!(mod) end)
        on = fn pat -> for {c, sql} <- sent, sql =~ pat, do: c end

        [set] = on.(~r/^SET statement_timeout/)
        builds = on.(~r/CREATE INDEX CONCURRENTLY/)
        assert length(builds) == length(unquote(names))
        assert Enum.all?(builds ++ on.(~r/DROP INDEX CONCURRENTLY/), &(&1 == set))
        assert on.(~r/^RESET statement_timeout/) == [set]
      end

      begin.()
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
