defmodule Engram.Backfill.TenantScan do
  @moduledoc """
  Enumerate every user and run a tenant-scoped function inside each one's RLS
  context. The discovery half of every operator backfill.

  ## Why this exists (#1349)

  A backfill has to answer "who needs work?" before it can enqueue anything,
  and the obvious way to ask — one cross-tenant query with
  `skip_tenant_check: true` — **returns zero rows on prod**:

  - `skip_tenant_check: true` only bypasses Engram's application-level guard in
    `Engram.Repo.prepare_query/3`. It does not set `app.current_tenant`.
  - The policy on every tenant table is
    `USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))`,
    which with no tenant set evaluates against NULL and filters every row.
  - `FORCE ROW LEVEL SECURITY` binds even the table owner, and the prod role
    has neither SUPERUSER nor BYPASSRLS.

  So the query succeeds, returns `[]`, and the backfill reports "nothing to
  do" on a database full of rows needing work. See
  `docs/context/migrations-force-rls-data-dml.md` — the same trap, previously
  documented only for migrations.

  **Dev and CI cannot catch this.** Their Postgres user is a superuser, which
  bypasses RLS regardless of FORCE, so the broken version passes locally and in
  CI. What `test/engram/backfill/tenant_scan_test.exs` asserts instead is
  structural: that a scan emits no `[:engram, :repo, :tenant_check_skipped]`
  telemetry for a tenant table. That holds under a superuser and fails the
  moment someone reintroduces a cross-tenant read.

  `users` carries no RLS (it is absent from `Engram.Repo.tenant_tables/0`), so
  enumerating it needs no tenant context — which is what makes it a usable
  starting point.
  """

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Repo

  require Logger

  @doc """
  Call `fun` once per user id, inside that user's tenant context, and
  concatenate the lists it returns.

  `fun` receives the user id and must return a list. Any query it runs sees
  exactly that user's rows, on prod and in dev alike.
  """
  @spec flat_map_users((Ecto.UUID.t() -> list())) :: list()
  def flat_map_users(fun) when is_function(fun, 1) do
    ids = user_ids()

    # Each user is its own committed transaction, so a failure midway leaves
    # real work already done. The old single-statement INSERT was all-or-
    # nothing; this is not, so the progress count is logged BEFORE re-raising —
    # otherwise an operator gets a stacktrace and no way to tell whether the
    # run did nothing or almost everything. Every caller is idempotent, so
    # re-running from the top is safe; knowing how far it got is what decides
    # whether that is necessary.
    ids
    |> Enum.reduce({[], 0}, fn user_id, {acc, done} ->
      case Repo.with_tenant(user_id, fn -> fun.(user_id) end) do
        {:ok, rows} when is_list(rows) ->
          {[rows | acc], done + 1}

        {:ok, other} ->
          {[[other] | acc], done + 1}

        {:error, _} = err ->
          Logger.error(
            "tenant scan aborted at user #{user_id} after #{done}/#{length(ids)} users " <>
              "(work already committed is NOT rolled back; re-running is safe): #{inspect(err)}"
          )

          raise "tenant scan failed for #{user_id}: #{inspect(err)}"
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    # concat, not List.flatten/1 — flatten would descend into nested lists a
    # caller legitimately returned as elements.
    |> Enum.concat()
  end

  # No tenant context needed: `users` is not a tenant table, so no RLS policy
  # applies and no `prepare_query/3` guard fires.
  defp user_ids do
    from(u in User, select: u.id) |> Repo.all()
  end
end
