defmodule Engram.Repo do
  use Ecto.Repo,
    otp_app: :engram,
    adapter: Ecto.Adapters.Postgres

  require Logger

  # MUST stay in lockstep with the set of tables that have ROW LEVEL SECURITY
  # enabled in the schema. `tenant_table_guard_test` asserts this list equals
  # the live RLS set so the two can't drift. onboarding_actions and
  # crdt_update_log were added 2026-06-29: the audit found them RLS-on in the
  # DB but absent here, so the prepare_query tripwire wasn't covering them
  # (Engram#788). Their access is already correct — onboarding_actions via
  # `skip_tenant_check`, crdt_update_log via `with_tenant` — so listing them
  # only tightens the guard, it doesn't change behavior.
  @tenant_tables ~w(notes chunks attachments api_keys vaults user_agreements onboarding_actions crdt_update_log note_links vault_index_states vault_index_update_log account_exports)a

  @doc """
  The tables guarded by `prepare_query/3`, which must equal the set of tables
  with ROW LEVEL SECURITY enabled in the schema. Exposed for the drift test.

  No `@spec`: the body is a compile-time-constant list, so any `[atom()]` spec
  is a dialyzer `contract_supertype` of the inferred literal type.
  """
  def tenant_tables, do: @tenant_tables

  @doc """
  The repo to use for work that legitimately spans tenants.

  Returns `Engram.Repo.Maintenance` where a second credential is configured,
  and `__MODULE__` otherwise — so a caller reads the same either way and
  self-host needs no second connection. See `Engram.Repo.Maintenance` for which
  deployment wants which, and `Engram.Repo.TenancyGuard` for what notices when
  the answer is wrong.

  Resolved per call rather than at compile time: `MAINTENANCE_DATABASE_URL` is
  read in `config/runtime.exs`, which runs after this module is built.

  No `@spec`, for the same reason `tenant_tables/0` above carries none: the
  body returns one of two literal module atoms, so `module()` is a dialyzer
  `contract_supertype` of the inferred `Engram.Repo | Engram.Repo.Maintenance`.
  """
  def maintenance do
    if Application.get_env(:engram, :maintenance_repo_enabled, false) do
      Engram.Repo.Maintenance
    else
      __MODULE__
    end
  end

  @doc """
  Take a transaction-scoped Postgres advisory lock keyed on a string id (a
  note/attachment/source-note UUID, etc). Released automatically at
  commit/rollback — the caller must already be inside a transaction (e.g.
  `with_tenant/2`) or the lock releases the instant this call returns.

  `hashtextextended(id, 0)` maps the string to the bigint advisory-lock
  keyspace. This is the ONE place that formula lives — any two callers that
  need to serialize on the SAME logical id must both call this, not
  reimplement the query, because the correctness of such a pair rests
  entirely on both sides hashing to an IDENTICAL key. Collisions across
  UNRELATED ids are tolerable (an unrelated write waits, a latency cost, not
  a correctness issue).

  Current caller: `Engram.Links.lock_source_note!/1`, serializing concurrent
  link-extraction writes for the same source note. The CRDT genesis-seed lock
  this was originally added for (#1409) was removed in round 4 — a
  post-commit room eviction replaced it, so genesis seeding no longer takes
  this lock.
  """
  @spec advisory_lock!(String.t()) :: :ok
  def advisory_lock!(id) when is_binary(id) do
    _ = query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [id])
    :ok
  end

  @doc """
  Executes `fun` inside a transaction with RLS tenant context set.

  Sets both the process-dict guard (for prepare_query) and the
  PostgreSQL transaction-local `app.current_tenant` (for RLS enforcement).

  `tenant_id` is a canonical UUID string (post PG18+UUIDv7 rework).
  The RLS policy compares `(user_id)::text = current_setting('app.current_tenant')`,
  so the bind value is the lower-case hyphenated UUID string.

  Wire shape: tenant + role drop are applied in ONE parameterized
  `SELECT set_config(...)` (`set_config(..., true)` is exactly SET LOCAL)
  and reset in one — hot requests open several tenant blocks, and the old
  three-utility-statement shape was pure fixed overhead per block.

  Re-entrant: a nested call for the SAME tenant inside an active
  with_tenant transaction runs `fun` directly (the settings are
  transaction-scoped and still in force) and returns `{:ok, result}` for
  shape-compatibility with the transactional path. A nested call for a
  DIFFERENT tenant raises — silently switching RLS identity
  mid-transaction is never legitimate.
  """
  def with_tenant(tenant_id, fun) when is_binary(tenant_id) do
    case Ecto.UUID.cast(tenant_id) do
      {:ok, uuid} ->
        case Process.get(:engram_tenant) do
          ^uuid ->
            if in_transaction?() do
              {:ok, fun.()}
            else
              run_with_tenant(uuid, fun)
            end

          nil ->
            run_with_tenant(uuid, fun)

          other ->
            raise ArgumentError,
                  "with_tenant nested for a different tenant " <>
                    "(active: #{other}, requested: #{uuid})"
        end

      :error ->
        raise ArgumentError,
              "tenant_id must be a canonical UUID string, got: #{inspect(tenant_id)}"
    end
  end

  def with_tenant(tenant_id, _fun) do
    raise ArgumentError,
          "tenant_id must be a canonical UUID string, got: #{inspect(tenant_id)}"
  end

  @doc """
  `with_tenant/2` returning the bare result instead of `{:ok, result}`.

  The transactional path returns `{:ok, result}` and the re-entrant path is
  shaped to match it, so `{:ok, _} = Repo.with_tenant(...)` appears at 11 call
  sites purely to unwrap something that cannot legitimately be anything else:
  the transaction only fails via `rollback/1`, which nothing inside a
  `with_tenant` block calls.

  Use this where the tuple carries no information. Keep `with_tenant/2` where
  a caller genuinely branches on the result.
  """
  def with_tenant!(tenant_id, fun) do
    {:ok, result} = with_tenant(tenant_id, fun)
    result
  end

  @doc """
  Runs `fun` with the tenant tripwire suspended, for queries that legitimately
  span tenants.

  This is the replacement for `skip_tenant_check: true`, and the difference is
  entirely one of legibility: the option sits at the end of a single query,
  often many lines from the `from(...)` it belongs to, and reads as a local
  detail. A block names the intent, covers every query inside it, and is
  visible in a diff.

  Neither one is a scope. Both suppress only `prepare_query/3`, an
  application-level guard; neither sets any Postgres session state. Where RLS
  is enforced, the queries inside this block are still filtered by the tenant
  policy unless the connecting role is exempt from it. That is what
  `Engram.Repo.Maintenance` is for, and when a call site needs the real thing
  it should run through `maintenance()`.

  Emits the same `:tenant_check_skipped` telemetry the keyword does, so the
  existing metric keeps counting the same population across the migration.

  Re-entrant: it restores the PREVIOUS flag value rather than clearing it, so
  a nested call cannot re-arm the tripwire for the remainder of an enclosing
  block. (An earlier version of this docstring called that "not re-entrant-safe
  by design", which inverts the conclusion — restoring the previous value is
  precisely what makes nesting safe.)

  The flag is process-local, so it does NOT propagate to a process spawned
  inside the block: a `Task.async_stream` or an `Engram.TaskSupervisor` fan-out
  started in here fails CLOSED with `Engram.TenantError` from the child, far
  from this call. That polarity is correct — a child that silently inherited a
  bypass is the worse failure — but it is surprising, so wrap the work inside
  the child rather than around the spawn.
  """
  def cross_tenant(fun) when is_function(fun, 0) do
    previous = Process.get(:engram_cross_tenant, false)
    Process.put(:engram_cross_tenant, true)

    try do
      fun.()
    after
      Process.put(:engram_cross_tenant, previous)
    end
  end

  defp run_with_tenant(uuid, fun) do
    Process.put(:engram_tenant, uuid)

    try do
      # `source:` is purely observability. Ecto reads it straight off the query
      # opts (`Ecto.Adapters.SQL.log/5`) and opentelemetry_ecto appends it to
      # the span name — there is no per-query naming hook, so without it these
      # statements render as bare `engram.repo.query`. Transaction opts reach
      # the same code path via `checkout_or_transaction/4`, so this also names
      # the begin/commit pair.
      #
      # Worth the three keywords: a 2026-08-02 trace audit found 3,069 of 5,389
      # repo.query spans anonymous over 23h, almost all of them this block on
      # the hot path (13 per GET /api/sync/manifest). Anonymous spans got read
      # as background-job noise; they are actually 7.9ms of tenant setup
      # against 5.1ms of real data queries.
      transaction(
        fn ->
          # `set_config(..., true)` == SET LOCAL, but as a regular SELECT it
          # takes a bind parameter (no string interpolation) and applies the
          # tenant + the engram_app role drop in a single round trip.
          # Superusers bypass RLS even with FORCE — the role drop scopes
          # enforcement to this transaction.
          _ =
            query!(
              "SELECT set_config('app.current_tenant', $1, true), " <>
                "set_config('role', 'engram_app', true)",
              [uuid],
              source: "tenant_enter"
            )

          result = fun.()
          # In Ecto Sandbox (tests), this transaction runs as a savepoint.
          # PostgreSQL's transaction-local settings span the full outer
          # transaction, so RELEASE SAVEPOINT would leak `engram_app` into
          # the sandbox transaction. Resetting the role INSIDE the
          # transaction (`set_config('role', 'none', true)` == SET LOCAL
          # ROLE NONE) ensures the last local setting that persists is the
          # default. In production this runs inside a real transaction and
          # is harmless.
          _ = query!("SELECT set_config('role', 'none', true)", [], source: "tenant_exit")
          result
        end,
        source: "tenant_txn"
      )
    after
      Process.delete(:engram_tenant)
    end
  end

  @doc """
  Safety net — raises if a tenant-scoped table is queried without
  `with_tenant/2`, `cross_tenant/1`, or an explicit `skip_tenant_check: true`.
  Uses process dict (zero-cost) rather than a DB query.
  """
  @impl true
  def prepare_query(_operation, query, opts) do
    if tenant_required?(query) do
      cond do
        # Properly scoped — the hot path. No telemetry, no overhead.
        not is_nil(Process.get(:engram_tenant)) ->
          :ok

        # Deliberate bypass (admin/cron/auth). Count it: a regression that adds
        # skip_tenant_check to a user-facing read shows up as a rate change on a
        # tenant table that should never be skipped on the request path.
        #
        # Two spellings, one meaning. The keyword is per-query; `cross_tenant/1`
        # is a block covering everything inside it. They emit the SAME event on
        # purpose — the metric measures how much of the system runs outside a
        # tenant scope, and splitting it per spelling would reset that baseline
        # to zero mid-migration and hide the answer.
        Keyword.get(opts, :skip_tenant_check, false) or
            Process.get(:engram_cross_tenant, false) ->
          emit_tenant_event(:tenant_check_skipped, query)

        # A tenant table queried with no scope and no bypass — the highest
        # severity failure mode in a multi-tenant system. Make it speak (a
        # tripwire metric + log) before the structural guard raises, instead of
        # relying on the unhandled-exception path alone.
        true ->
          emit_tenant_event(:tenant_guard_violation, query)

          Logger.error(
            "tenant_guard_violation",
            Engram.Logger.Metadata.with_category(:error, :boot, table: table_of(query))
          )

          raise Engram.TenantError,
            message: "Tenant context not set! Use Repo.with_tenant/2 for tenant-scoped queries."
      end
    end

    {query, opts}
  end

  @tenant_table_strings Enum.map(@tenant_tables, &Atom.to_string/1)

  defp tenant_required?(%Ecto.Query{from: %{source: {table, _}}}) do
    table in @tenant_table_strings
  end

  defp tenant_required?(_), do: false

  defp table_of(%Ecto.Query{from: %{source: {table, _}}}), do: table
  defp table_of(_), do: nil

  defp emit_tenant_event(event, query) do
    :telemetry.execute([:engram, :repo, event], %{count: 1}, %{table: table_of(query)})
  end
end
