defmodule Engram.Repo.Migrations.LockTimeoutRetry do
  @moduledoc """
  Runs a migration's statements on one pinned connection under a 5 s
  `lock_timeout`, and retries a statement that hits it (55P03) twice before
  it raises, so a busy table does not crash boot.

  Shared by migrations through `Code.require_file("lock_timeout_retry.exs",
  __DIR__)`, not through `lib/`: the N-1 gate (verify.yml, n1-compat) runs
  new migrations with the PREVIOUS release's code, which lacks any new
  `lib/` module. That gate copies every `priv/repo/migrations/*.exs` the
  previous tree lacks, this file included, and Ecto's migrator skips a file
  whose name has no version prefix. Applied migrations depend on this file,
  so treat it as frozen like them: change behaviour in a new file.

  Use with `@disable_ddl_transaction true`: inside a transaction a lock
  timeout aborts the whole transaction, so a single statement cannot be
  retried. Every statement must be rerun-safe on its own.
  """

  @lock_retries 2

  # `timeout: :infinity` on the checkout: DBConnection's 15 s default is a
  # deadline for the whole block (a per-query timeout does not extend it), and
  # a VALIDATE scan plus a few lock waits can pass it at boot (the 0.79.0
  # incident mechanism). The 5 s `lock_timeout` is the bound on lock waits.
  def with_lock_timeout(repo, statements) do
    repo.checkout(
      fn ->
        repo.query!("SET lock_timeout = '5s'")

        try do
          Enum.each(statements, &run(repo, &1, @lock_retries))
        after
          repo.query!("RESET lock_timeout")
        end
      end,
      timeout: :infinity
    )
  end

  # Only the failed statement is retried: it changed nothing, and starting
  # over would repeat any earlier scan.
  defp run(repo, statement, retries) do
    repo.query!(statement, [], timeout: :infinity)
  rescue
    e in Postgrex.Error ->
      if retries > 0 and match?(%{postgres: %{code: :lock_not_available}}, e),
        do: run(repo, statement, retries - 1),
        else: reraise(e, __STACKTRACE__)
  end
end
