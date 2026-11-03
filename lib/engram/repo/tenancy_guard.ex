defmodule Engram.Repo.TenancyGuard do
  @moduledoc """
  Boot-time report on whether this deployment actually enforces RLS, and
  whether it is configured to survive doing so.

  ## Why this has to ask Postgres

  Every local signal for "is RLS on?" lies. The tables have had `ENABLE` +
  `FORCE ROW LEVEL SECURITY` and a correct policy for months, and the policy
  was never the problem: dev and CI *connect as a superuser*, and a superuser
  bypasses RLS even under FORCE. So the schema says enforced, the config says
  nothing, and the truth is a property of the credential in `DATABASE_URL` —
  which only the server can answer.

  This used to say SaaS prod connected as a superuser too. It does not.
  `0.29.0` measured `engram_admin` from inside the app's own pool: neither
  `rolsuper` nor `rolbypassrls`.

  This paragraph also used to claim `0.30.0`'s probe saw zero rows across all
  eleven tenant tables on prod. **That was never measured.** `probe_opts/0`
  documents why: the probe's transaction failed on every outermost caller, so
  `observed_enforcement/0` returned `:unknown` on prod every time and the reads
  never ran. The claim was an inference from a boot log that only ever showed
  the attribute answer. What prod's behaviour is remains OPEN — see
  `docs/context/rls-tenancy-probe-boot-log.md`, and re-measure once a release
  carrying the `probe_opts/0` fix has rolled.

  ## Why it asks Postgres to DEMONSTRATE it, not to describe itself

  The original version of this guard asked:

      SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user

  That is a question about the role's *attributes*, not about what the
  connection can *see* — and on SaaS prod those two disagree. `engram_admin`
  reads `rolsuper = false, rolbypassrls = false`, so the attribute query says
  "enforced", while `engram-app/Engram#1649` recorded a tenant verifiably set
  and `select count(*) from notes` still returning all 3,602 rows. Nobody has
  reproduced the mechanism; `pg_read_all_data` was proposed and disproved
  (#1726). What is certain is that the attribute answer did not predict the
  behaviour, which made a guard built on it capable of reporting `:enforced`
  on a deployment where RLS demonstrably was not.

  So the probe asks four questions, none of which reads a whole table:

    1. `row_security_active(oid)` per tenant table: false for RLS disabled, an
       owner without FORCE, BYPASSRLS or a superuser.
    2. Is `current_user` the app role? The maintenance role's
       `maintenance_all ... USING (true)` policies admit every row with every
       flag right.
    3. The policies: every permissive policy that applies to this role must
       be the table's tenant predicate (or an allowed "no tenant set"
       discovery policy), and every table must have one. A `USING (true)`
       policy passes 1 and 2; this catches it.
    4. The behaviour, index-bounded: under a tenant that owns nothing, can a
       row of a real user be read? `user_id = ANY(<20 ids>) LIMIT 1` on each
       table whose index leads with `user_id`, so it is index descents, never
       the full-table read the old probe needed to prove "nothing visible"
       (up to 7.3 s per boot on prod `chunk_points`). It still reads a row it
       does not own: that is the measurement (#1726, role membership, which
       no attribute shows).

  Every tenant table is probed, not just one, because RLS state is per-table
  and this repo toggles it per-table as routine practice — ten migrations
  issue `NO FORCE ROW LEVEL SECURITY` and re-`FORCE` at the end. An
  interrupted one leaves a single table exposed while the rest are fine.

  The probe answers `:bypassed` or nothing. It cannot assert `:enforced`, and
  that asymmetry is deliberate: seeing no rows has three causes and the probe
  can distinguish only one of them — the policy filtered us, the table is
  empty, or the rows exist but are invisible to this transaction. Seeing a row
  that should be hidden has exactly one cause, which is why the positive
  direction is the only one worth claiming.

  An earlier version tried to rule out "empty" with `pg_class.reltuples`. That
  was wrong in a way worth recording: reltuples is a table-wide,
  NON-transactional statistic, so under the Ecto sandbox it reports the whole
  table while the connection sees only its own uncommitted rows — which reads
  as `:enforced` on a database enforcing nothing. It turned CI red while the
  same test passed alone locally.

  ## What the answer is allowed to change

  Nothing, on its own. `enforcement/0` combines the probe with the attribute
  answer and only reports `:bypassed` when BOTH agree, because `enforced?/0`
  gates irreversible deletions in `Engram.Workers.OrphanSweep`. A diagnostic
  improving is not grounds for unlocking those; that is its own decision.

  Both answers are still collected, and `report_divergence/2` says so when they
  disagree. That divergence IS #1726, and if it recurs it should arrive as a
  sentence rather than as another multi-day investigation.

  ## What it does about the answer

  Enforcement on and no maintenance pool configured is the broken combination:
  cross-tenant sweeps are filtered to zero rows, report success, and log
  nothing. This logs an error and emits telemetry for it.

  It does **not** refuse to boot, and the restraint is the point. A guard that
  crashes should only ever fire where the operator has a fix available, and
  until the sweeps are actually moved onto `Engram.Repo.Maintenance` setting
  `MAINTENANCE_DATABASE_URL` changes nothing — so raising here would turn a
  pre-existing silent bug into a fresh outage and teach nobody anything. The
  raise belongs in the change that finishes the job.

  Runs in `init/1`, after `Engram.Repo` is in the supervision tree, then
  returns `:ignore` so no process lingers. Same shape as
  `Engram.Crypto.BootCanaryGuard`, minus the fail-loud.
  """

  use GenServer

  alias Engram.Logger.Metadata

  require Logger

  # A tenant that owns nothing. Any row visible while this is the current
  # tenant belongs to somebody else, which is the whole question.
  import Ecto.Query, only: [from: 2]

  @nobody "00000000-0000-0000-0000-000000000000"

  @doc """
  Whether the connecting role is subject to RLS: `:enforced`, `:bypassed`, or
  `:unknown`.

  Answered by what the connection can SEE (see the moduledoc). The role's
  `pg_roles` attributes are collected too, but only so a disagreement between
  the two can be reported — on SaaS prod they disagree, and that disagreement
  is `engram-app/Engram#1726`.

  Uses the non-bang `query/3` deliberately. This runs in `init/1`, and an
  `init/1` raise makes `start_link` return `{:error, _}`, which fails
  `Supervisor.start_link` and therefore `Application.start/2` — the exact
  fail-loud mechanism `Engram.Crypto.BootCanaryGuard` is built on, and
  `restart: :temporary` does not save it. A statement timeout or a connection
  blip during boot would then hard-crash the one component whose whole design
  statement is "log, never refuse to boot". `:unknown` is as alarming as
  `:misconfigured` and now produces a sentence rather than a crash.
  """
  @spec enforcement() :: :enforced | :bypassed | :unknown
  def enforcement, do: combine(observed_enforcement(), claimed_enforcement())

  # `:bypassed` requires BOTH signals to agree, and that asymmetry is the whole
  # safety property.
  #
  # `enforced?/0` gates `Engram.Workers.OrphanSweep`, which deletes Qdrant
  # points and S3 prefixes irreversibly. Prod today refuses every run because
  # the attribute answer is `:enforced`. Letting the probe alone flip that to
  # `:bypassed` would silently start those deletions on the strength of a
  # signal whose mechanism #1726 says nobody has identified — a behaviour
  # change that belongs in its own reviewed decision, not smuggled in as a side
  # effect of improving a diagnostic.
  #
  # So disagreement resolves to the cautious side. The divergence is still
  # reported loudly at boot; it just does not unlock anything on its own.
  @doc """
  Resolve the two signals into the answer everything downstream uses.

  Public so the truth table can be asserted directly. It cannot be driven from
  a test connection: `SET ROLE` changes `current_user`, which is what BOTH the
  attribute read and RLS row visibility key off, so there is no way to make the
  two signals genuinely disagree in a sandbox. The disagreement only exists on
  prod, which is the entire problem.
  """
  @spec combine(:enforced | :bypassed | :unknown, :enforced | :bypassed | :unknown) ::
          :enforced | :bypassed | :unknown

  # Either signal claiming enforcement wins, including when they disagree.
  # Costs a refused sweep and a log line; the other direction costs data.
  def combine(:enforced, _), do: :enforced
  def combine(_, :enforced), do: :enforced

  # Neither could speak: a fresh database where every tenant table is empty AND
  # the attribute read failed. `enforced?/0` reads this as true, same cautious
  # direction.
  def combine(:unknown, :unknown), do: :unknown

  # What is left: at least one signal observed a bypass and neither observed
  # enforcement. `:unknown` is an ABSTENTION, not a veto — treating it as one
  # is the bug this clause exists to prevent. It made OrphanSweep refuse on
  # every empty database, which is every fresh self-host install and four of
  # its own tests.
  def combine(_, _), do: :bypassed

  @doc """
  What the role's `pg_roles` attributes CLAIM, which is not the same question.

  Kept because the divergence is the finding. A role that is `rolsuper` or
  `rolbypassrls` reads every row regardless of policy, so a `true` here means
  enforcement is off for it — but a `false` does not establish the converse,
  which is exactly the trap #1649 fell into.
  """
  @spec claimed_enforcement() :: :enforced | :bypassed | :unknown
  def claimed_enforcement do
    case Engram.Repo.query(
           "SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user",
           [],
           source: "tenancy_guard"
         ) do
      {:ok, %{rows: [[true]]}} -> :bypassed
      {:ok, %{rows: [[false]]}} -> :enforced
      # No row for current_user should be impossible, and a failed query is the
      # realistic unknown. Both land here rather than being guessed at.
      {:ok, _} -> :unknown
      {:error, _} -> :unknown
    end
  end

  @doc """
  What the connection can actually see: the behavioural probe.

  Checks the RLS flags, the role and the policies of EVERY tenant table, then
  adopts a tenant that owns nothing and asks whether a real user's row is
  reachable anyway (through the `user_id` index, never a scan). One leak anywhere is decisive: RLS state is
  per-table, and this repo toggles it per-table as routine practice — ten
  migrations under `priv/repo/migrations` issue `ALTER TABLE <t> NO FORCE ROW
  LEVEL SECURITY` and re-`FORCE` at the end. An interrupted one leaves a single
  table exposed while the rest are fine, which is precisely the state a
  single-table probe cannot see. (It is also the most checkable candidate yet
  for #1726's unexplained mechanism, and unlike `pg_read_all_data` nobody has
  ruled it out.)

  Wrapped in a transaction so `set_config/3`'s local flag has a scope to be
  local TO. The caller's tenant is saved first and restored before returning,
  rather than rolled back: rolling back would discard the caller's own work if
  this ever runs inside their transaction.
  """
  @spec observed_enforcement() :: :enforced | :bypassed | :unknown
  def observed_enforcement do
    # See `probe_opts/0` for why the transaction mode is decided at call time.
    #
    # try/rescue because `Repo.transaction/2` does NOT convert a pool checkout
    # failure into `{:error, _}` the way `query/3` does; it raises
    # `DBConnection.ConnectionError`. This is called from `init/1`, where a
    # raise fails the supervisor and therefore `Application.start/2` — exactly
    # the boot crash the moduledoc's "log, never refuse to boot" rule exists to
    # prevent. A slow database at boot must not take the app down.
    run_probe()
  end

  # Implicit `try` — the whole body is the protected expression, so credo's
  # Readability.PreferImplicitTry applies.
  #
  # NOT `try/rescue/else`, which an earlier version used: a rescue clause's
  # value is returned DIRECTLY and does not flow through `else`, so the error
  # tuple escaped as this function's result. The tests caught it, which is the
  # only reason it is not still in here.
  defp run_probe do
    case Engram.Repo.transaction(&probe/0, probe_opts()) do
      {:ok, verdict} -> verdict
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  @doc """
  Transaction options for the probe, decided at call time.

  `mode: :savepoint` is only valid INSIDE an existing transaction — it issues
  `SAVEPOINT`, which Postgres rejects with no enclosing `BEGIN`. Passing it
  unconditionally failed the transaction on every real caller (`init/1` at
  boot, and the top of the `OrphanSweep` and `CrdtBloatSweep` Oban jobs are
  all outermost), tore down the pooled connection with
  `DBConnection.TransactionError: transaction is not started`, and left
  `run_probe/0` reporting `:unknown`.

  That failed silently for two reasons worth stating, because both are traps
  this module has now hit twice:

    * `:unknown` is a legitimate verdict — a fresh install with no rows
      returns it — so `combine/2` fell back to the attribute answer and
      nothing logged a defect.
    * Every test of the probe runs under `Engram.DataCase`, whose sandbox
      already holds a transaction open, so the savepoint was always valid in
      the suite. The shape that ships was the one shape never exercised.
      `tenancy_guard_outermost_test.exs` exists to close that gap and checks
      out with `sandbox: false` deliberately.

  Public only so that test can assert both shapes without reading source.
  """
  @spec probe_opts() :: keyword()
  def probe_opts do
    # Still `:savepoint` when nested, so aborting the probe cannot roll back a
    # caller's own work. No caller does this today; it is cheap insurance
    # against one appearing.
    if Engram.Repo.in_transaction?(), do: [mode: :savepoint], else: []
  end

  defp probe do
    previous = current_tenant()

    verdict =
      case set_tenant(@nobody) do
        {:ok, _} -> probe_all_tenant_tables()
        _ -> :unknown
      end

    # Restore rather than roll back. The savepoint already covers the raise
    # path — a raise aborts the subtransaction, which reverts the SET LOCAL
    # without our help.
    #
    # Return deliberately discarded: `set_config` fails only if the connection
    # is already gone, in which case there is no tenant left to restore. Bound
    # explicitly so dialyzer's unmatched_returns stays on for the rest of the
    # module.
    _ = set_tenant(previous)

    verdict
  end

  # Any one table leaking is decisive and short-circuits. Otherwise the probe
  # has NO OPINION — `:unknown` — and `combine/2` defers to the attribute
  # answer.
  #
  # It deliberately cannot return `:enforced`. Seeing no rows has three causes
  # and the probe can only distinguish one of them: the policy filtered us, the
  # table is empty, or the rows exist but are invisible to this transaction.
  # An earlier version used `pg_class.reltuples` to rule out "empty" — but
  # reltuples is a table-wide, non-transactional statistic, so under the Ecto
  # sandbox it reports the whole table while the connection sees only its own
  # uncommitted rows. That combination reads as `:enforced` on a database that
  # is not enforcing anything, and it is what turned CI red while the same test
  # passed alone locally.
  #
  # Detecting a BYPASS is the probe's whole job and the only thing it can
  # honestly assert. #1726 is a question about rows being visible that should
  # not be, and a positive answer to that needs no disambiguation.
  defp probe_all_tenant_tables do
    names = Enum.map(Engram.Repo.tenant_tables(), &Atom.to_string/1)

    # Four checks, none of which can scan a table (the old row probe proved
    # "nothing visible" by reading the whole table under RLS: prod
    # `chunk_points` up to 7.3 s per boot, Job Load Audit 2026-11-03). Any
    # one failing is a bypass; all passing is still no opinion, as before.
    cond do
      rls_inactive?(names) -> :bypassed
      not app_role?() -> :bypassed
      leaky_policy?(names) -> :bypassed
      rows_visible?(names) -> :bypassed
      true -> :unknown
    end
  end

  # 1. Catalog: `row_security_active/1` is false for a table with RLS
  #    disabled, an owner without FORCE, BYPASSRLS or a superuser.
  defp rls_inactive?(names) do
    case query(
           """
           SELECT bool_and(row_security_active(c.oid)), count(*)
           FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND c.relname = ANY($1)
           """,
           [names]
         ) do
      {:ok, %{rows: [[true, n]]}} -> n != length(names)
      {:ok, _} -> true
      _ -> false
    end
  end

  # 2. The connection is the app role. The maintenance role (whose
  #    `maintenance_all ... USING (true)` policies admit every row), or any
  #    other role, reads other tenants' rows with every flag right.
  defp app_role? do
    case query("SELECT current_user::text", []) do
      {:ok, %{rows: [[role]]}} -> role == app_role()
      _ -> true
    end
  end

  @doc false
  def app_role, do: Application.get_env(:engram, :app_db_role, "engram_app")

  # Permissive policies that may apply to the app role besides the tenant
  # predicates: `subscriptions_discovery` matches only with NO tenant set (the
  # webhook lookup by Paddle id); its qual is checked, not just its name.
  @discovery_policies ["subscriptions_discovery"]

  # 3. Policies: every permissive policy that applies to `current_user`
  #    (PUBLIC, or a role it is a member of) must be the table's tenant
  #    predicate on `app.current_tenant`, or an allowed discovery policy whose
  #    qual is "no tenant set". A `USING (true)` policy, a tenant policy that
  #    does not test the tenant, or a table with no tenant policy fails.
  @policy_audit """
  WITH t AS (
    SELECT c.oid, c.relname FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = ANY($1)),
  p AS (
    SELECT t.relname, p.polname, pg_get_expr(p.polqual, p.polrelid) AS qual
    FROM pg_policy p JOIN t ON t.oid = p.polrelid
    WHERE p.polpermissive
      AND (0 = ANY(p.polroles) OR EXISTS (
        SELECT 1 FROM unnest(p.polroles) r
        WHERE r <> 0 AND pg_has_role(current_user, r, 'USAGE'))))
  SELECT
    EXISTS (SELECT 1 FROM p
            WHERE NOT (p.polname = 'tenant_isolation_' || p.relname
                       AND p.qual LIKE '%user_id = %app.current_tenant%')
              AND NOT (p.polname = ANY($2)
                       AND p.qual LIKE '%COALESCE(%app.current_tenant%) = %'))
    OR EXISTS (SELECT 1 FROM t WHERE NOT EXISTS (
            SELECT 1 FROM p WHERE p.relname = t.relname
              AND p.polname = 'tenant_isolation_' || t.relname))
  """

  defp leaky_policy?(names) do
    case query(@policy_audit, [names, @discovery_policies]) do
      {:ok, %{rows: [[leaky]]}} -> leaky
      _ -> false
    end
  end

  # 4. Behaviour, index-bounded: under a tenant that owns nothing, can a row
  #    of a real user be read? Each read is `user_id = ANY(<up to 20 user
  #    ids>)` with LIMIT 1 on a table whose index leads with `user_id`: at most
  #    20 index descents, never a scan. A table without such an index is
  #    covered by checks 1-3.
  @user_id_indexed """
  SELECT DISTINCT c.relname FROM pg_index i
  JOIN pg_class c ON c.oid = i.indrelid
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
  WHERE c.relname = ANY($1) AND a.attname = 'user_id'
  """

  defp rows_visible?(names) do
    with {:ok, %{rows: [_ | _] = users}} <-
           query("SELECT id FROM users ORDER BY id LIMIT 20", []),
         {:ok, %{rows: tables}} <- query(@user_id_indexed, [names]) do
      ids = Enum.map(users, fn [id] -> Ecto.UUID.load!(id) end)
      Enum.any?(tables, fn [table] -> visible?(String.to_existing_atom(table), ids) end)
    else
      _ -> false
    end
  end

  defp query(sql, params), do: Engram.Repo.query(sql, params, source: "tenancy_guard")

  defp current_tenant do
    case Engram.Repo.query("SELECT current_setting('app.current_tenant', true)", [],
           source: "tenancy_guard"
         ) do
      {:ok, %{rows: [[tenant]]}} when is_binary(tenant) -> tenant
      # NULL when never set in this session. `set_config` wants a string, and
      # empty is what the rest of the codebase uses for "no tenant".
      _ -> ""
    end
  end

  defp set_tenant(value) do
    Engram.Repo.query("SELECT set_config('app.current_tenant', $1, true)", [value],
      source: "tenancy_guard"
    )
  end

  # One clause per tenant table, generated at COMPILE time: a structured query,
  # because a table name cannot be a bind parameter and interpolated SQL is a
  # security-scanner finding. `skip_tenant_check: true` is the accurate
  # declaration: the probe set a tenant that owns nothing and asks the SERVER
  # whether the policy filters; the ORM tripwire would refuse the query first.
  for table <- Engram.Repo.tenant_tables() do
    defp visible?(unquote(table), ids) do
      Engram.Repo.exists?(
        from(t in unquote(Atom.to_string(table)),
          where: t.user_id in type(^ids, {:array, Ecto.UUID})
        ),
        skip_tenant_check: true,
        source: "tenancy_guard"
      )
    end
  end

  @doc """
  `true` when the connecting role is subject to RLS.

  `:unknown` reports `true` so the noisy branch is the one that fires: a false
  alarm costs a log line, the other direction hides the bug.
  """
  @spec enforced?() :: boolean()
  def enforced?, do: enforcement() != :bypassed

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [])
  end

  @impl true
  def init(_) do
    observed = observed_enforcement()
    claimed = claimed_enforcement()

    report_divergence(observed, claimed)
    # `combine/2`, NOT `observed`. Reporting the raw probe result made the boot
    # line contradict the runtime behaviour: on a fresh self-host with empty
    # tables the probe returns `:unknown`, so boot logged "could not determine
    # whether RLS is enforced" as an ERROR on every start while `enforced?/0`
    # was quietly answering from the attributes. The log must describe the
    # answer the system actually uses.
    report(combine(observed, claimed), Engram.Repo.maintenance() != Engram.Repo)

    :ignore
  end

  # Agreement is the normal case and says nothing worth a line.
  defp report_divergence(same, same), do: :ok

  # One side abstained, so there are not two answers to disagree. `combine/2`
  # has already resolved it; calling that a divergence would report the absence
  # of evidence as evidence.
  defp report_divergence(:unknown, _claimed), do: :ok
  defp report_divergence(_observed, :unknown), do: :ok

  defp report_divergence(observed, claimed) do
    :telemetry.execute([:engram, :repo, :tenancy_divergence], %{count: 1}, %{})

    Logger.warning(
      """
      RLS role attributes and observed behaviour DISAGREE.

      pg_roles says: #{claimed}
      what this connection can actually see says: #{observed}

      This is engram-app/Engram#1726. On SaaS prod, engram_admin reads
      rolsuper=false and rolbypassrls=false — attributes that should mean
      enforced — while a tenant-scoped read returned every row. The mechanism
      has never been identified; pg_read_all_data was proposed and disproved.

      While they disagree, everything downstream takes the CAUTIOUS answer —
      enforced — because `enforced?/0` gates irreversible deletions in
      OrphanSweep. A disagreement is not enough to unlock those.

      Treat this line as the finding, not as noise: it means the deployment is
      in the state nobody has explained. The most checkable candidate is an
      interrupted migration leaving one table on NO FORCE ROW LEVEL SECURITY —
      ten migrations in this repo use that pattern. Compare `relrowsecurity`
      and `relforcerowsecurity` across the tenant tables before looking
      anywhere else.
      """,
      Metadata.with_category(:warning, :boot, [])
    )
  end

  defp report(:unknown, _maintenance_pool?) do
    :telemetry.execute([:engram, :repo, :tenancy_unknown], %{count: 1}, %{})

    Logger.error(
      "could not determine whether RLS is enforced for this connection",
      Metadata.with_category(:error, :boot, [])
    )
  end

  defp report(:enforced, false = _maintenance_pool?) do
    :telemetry.execute([:engram, :repo, :tenancy_misconfigured], %{count: 1}, %{})

    Logger.error(
      """
      RLS is ENFORCED for this connection, but no maintenance pool is configured.

      Cross-tenant work (orphan reaping, expiry sweeps, credential lookups that
      discover a user_id) is being filtered by the tenant policy. Those queries
      do not fail: reads return zero rows and writes report zero affected, so
      the jobs log success while doing nothing.

      Fix: set MAINTENANCE_DATABASE_URL to a credential whose role is exempt
      from the tenant policy. Self-host does not need this — a single-tenant box
      connects as its own database owner and never reaches this branch.
      """,
      Metadata.with_category(:error, :boot, [])
    )
  end

  defp report(:enforced, true = _maintenance_pool?) do
    Logger.info(
      "RLS enforced; maintenance pool configured",
      Metadata.with_category(:info, :boot, [])
    )
  end

  defp report(:bypassed, _maintenance_pool?) do
    # Info rather than warning because this is the CORRECT state for self-host
    # and for dev/CI, where a single-tenant box connects as its own database
    # owner and RLS has nothing to separate.
    #
    # It is no longer the state of SaaS prod, whatever this comment used to
    # say: prod has measured as not-bypassed since 2026-09-23 (role attributes)
    # and 2026-09-24 (row visibility). If this branch ever fires on prod it is
    # a finding, not a status line — see
    # `docs/context/rls-tenancy-probe-boot-log.md`.
    Logger.info(
      "RLS NOT enforced: the connecting role bypasses row security",
      Metadata.with_category(:info, :boot, [])
    )
  end
end
