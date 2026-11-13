defmodule Engram.Repo.Migrations.BoundedIndexBuild do
  @moduledoc """
  Builds `CREATE INDEX CONCURRENTLY` indexes at boot inside ONE time budget,
  one builder at a time, the way 20261112100000 does (it inlines the same
  logic; applied migrations are frozen, so this file is that logic shared
  for the ones after it). See that file's moduledoc for why each part is
  there:

    * one pinned connection, checked out for at most `checkout_ms`;
    * before each statement `statement_timeout` is what is left of that
      budget less a 5 s margin, so the server cancels a build before the
      client gives up and no orphaned build outlives the checkout; under a
      10 s floor the boot raises instead of starting a build bound to fail;
    * a session advisory lock (`lock_key`) on the building connection,
      polled with `pg_try_advisory_lock` (a blocking wait holds a snapshot
      the other CONCURRENTLY build waits on), so a SIGKILLed task's orphaned
      build is waited out rather than dropped as INVALID;
    * an INVALID index (a failed or cancelled build) is dropped, then each
      index is built IF NOT EXISTS: rerun-safe with no operator step.

  Shared through `Code.require_file("bounded_index_build.exs", __DIR__)`,
  not `lib/`, for the reason given in lock_timeout_retry.exs. Treat it as
  frozen once a merged migration requires it: change behaviour in a new
  file.
  """

  @margin_ms 5_000
  @min_statement_ms 10_000
  @lock_poll_ms 1_000

  @doc """
  Builds `indexes` (`[{name, "ON table (...) WHERE ..."}]`) on `repo`.
  `opts`: `:lock_key` (integer, unique per migration), `:checkout_ms`
  (default 110_000) and `:label` (for the floor error).
  """
  def build!(repo, indexes, opts) do
    checkout_ms = Keyword.get(opts, :checkout_ms, 110_000)

    budget = %{
      deadline: System.monotonic_time(:millisecond) + checkout_ms,
      checkout_ms: checkout_ms,
      label: Keyword.fetch!(opts, :label)
    }

    lock_key = Keyword.fetch!(opts, :lock_key)

    repo.checkout(
      fn ->
        lock!(repo, budget, lock_key)

        try do
          for {name, spec} <- indexes do
            if invalid?(repo, name),
              do: bounded!(repo, budget, "DROP INDEX CONCURRENTLY IF EXISTS #{name}")

            bounded!(repo, budget, "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{name} #{spec}")
          end
        after
          repo.query!("RESET statement_timeout")
          repo.query!("SELECT pg_advisory_unlock($1)", [lock_key], log: false)
        end
      end,
      timeout: checkout_ms
    )
  end

  defp invalid?(repo, name) do
    %{rows: rows} =
      repo.query!(
        "SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid " <>
          "WHERE c.relname = $1 AND NOT i.indisvalid",
        [name],
        log: false
      )

    rows != []
  end

  defp bounded!(repo, budget, sql) do
    repo.query!("SET statement_timeout = #{left!(budget)}")
    repo.query!(sql, [], timeout: :infinity)
  end

  defp lock!(repo, budget, lock_key) do
    _ = left!(budget)

    case repo.query!("SELECT pg_try_advisory_lock($1)", [lock_key], log: false) do
      %{rows: [[true]]} ->
        :ok

      _ ->
        Process.sleep(@lock_poll_ms)
        lock!(repo, budget, lock_key)
    end
  end

  defp left!(%{deadline: deadline, checkout_ms: checkout_ms, label: label}) do
    left = deadline - System.monotonic_time(:millisecond) - @margin_ms

    if left < @min_statement_ms,
      do:
        raise(
          "#{label}: #{left} ms left of the #{checkout_ms} ms budget, under the " <>
            "#{@min_statement_ms} ms floor; the next boot retries"
        )

    left
  end
end
