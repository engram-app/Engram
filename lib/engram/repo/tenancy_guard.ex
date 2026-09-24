defmodule Engram.Repo.TenancyGuard do
  @moduledoc """
  Boot-time report on whether this deployment actually enforces RLS, and
  whether it is configured to survive doing so.

  ## Why this has to ask Postgres

  Every local signal for "is RLS on?" lies. The tables have had `ENABLE` +
  `FORCE ROW LEVEL SECURITY` and a correct policy for months, and the policy
  was never the problem: dev, CI, and (at the time of writing) SaaS prod all
  *connect as a superuser*, and a superuser bypasses RLS even under FORCE. So
  the schema says enforced, the config says nothing, and the truth is a
  property of the credential in `DATABASE_URL` — which only the server can
  answer.

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

  So the probe is now behavioural. Adopt a tenant that owns nothing, and ask
  whether any row is visible anyway:

      SET LOCAL app.current_tenant = '00000000-...-000000000000'
      SELECT EXISTS (SELECT 1 FROM <each tenant table> LIMIT 1)

  `true` means rows belonging to other tenants are reachable — bypassed, no
  matter what `pg_roles` claims. Each read is bounded by `LIMIT 1`, and the
  caller's tenant is saved and restored around the whole thing.

  It deliberately DOES read a row it does not own. That is the measurement.

  Every tenant table is probed, not just one, because RLS state is per-table
  and this repo toggles it per-table as routine practice — ten migrations
  issue `NO FORCE ROW LEVEL SECURITY` and re-`FORCE` at the end. An
  interrupted one leaves a single table exposed while the rest are fine.

  A negative result is ambiguous on its own: an enforced connection and an
  empty table look identical. `pg_class.reltuples` disambiguates, because the
  catalog is not RLS-filtered — no visible rows against a table the planner
  believes is populated is enforcement; no visible rows against an apparently
  empty table is `:unknown`, not a clean bill of health. Note the estimate is
  stale between `ANALYZE` runs, so a table emptied since the last one reads as
  populated and yields `:enforced`. That error is in the cautious direction.

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

  Adopts a tenant that owns nothing and asks, of EVERY tenant table, whether
  any row is reachable anyway. One leak anywhere is decisive: RLS state is
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
    # `mode: :savepoint` so a nested call opens a subtransaction instead of
    # joining the caller's. No current caller invokes this from inside a
    # transaction — `OrphanSweep` and `CrdtBloatSweep` both ask at the top of
    # their Oban job — so this is defensive rather than load-bearing today.
    # Said plainly because an earlier version of this comment claimed otherwise
    # and would have justified removing it.
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
    case Engram.Repo.transaction(&probe/0, mode: :savepoint) do
      {:ok, verdict} -> verdict
      _ -> :unknown
    end
  rescue
    _ -> :unknown
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

  # Any one table leaking is decisive and short-circuits. Otherwise the answer
  # is the WEAKEST claim across the tables we could read: `:enforced` only if
  # at least one table was populated enough to prove it, `:unknown` if none
  # were. That ordering matters — an empty database must not read as enforced.
  defp probe_all_tenant_tables do
    Enum.reduce_while(Engram.Repo.tenant_tables(), :unknown, fn table, acc ->
      case probe_table(table) do
        :bypassed -> {:halt, :bypassed}
        :enforced -> {:cont, :enforced}
        :unknown -> {:cont, acc}
      end
    end)
  end

  defp probe_table(table) do
    with {:ok, %{rows: [[visible?]]}} <- probe_visibility(table),
         {:ok, %{rows: [[estimated_rows]]}} <- estimate_rows(table) do
      verdict(visible?, estimated_rows)
    else
      _ -> :unknown
    end
  end

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

  @doc """
  The decision the probe's two readings imply. Public only so it can be tested
  without a database — the interesting cases are the ones a sandbox cannot
  easily produce.
  """
  @spec verdict(boolean(), number()) :: :enforced | :bypassed | :unknown

  # `true` is decisive on its own: a row belonging to another tenant was
  # readable, so nothing is being enforced.
  def verdict(true, _estimated_rows), do: :bypassed

  # `false` is only meaningful against a table the planner believes has rows.
  # On an empty table an enforced connection and a bypassed one look identical,
  # and calling that `:enforced` would be a clean bill of health we did not
  # earn. `reltuples` is -1 on a never-analyzed table and 0 on a genuinely
  # empty one; neither can support the claim.
  def verdict(false, estimated_rows) when estimated_rows > 0, do: :enforced
  def verdict(false, _estimated_rows), do: :unknown

  # Interpolated, not a bind parameter: a table name cannot be one. Safe
  # because the only source is `Engram.Repo.tenant_tables/0`, a compile-time
  # literal list of atoms, and `to_string/1` on an atom cannot introduce
  # anything else. Asserted rather than assumed — see the guard clause.
  defp probe_visibility(table) when is_atom(table) do
    Engram.Repo.query("SELECT EXISTS (SELECT 1 FROM #{table} LIMIT 1)", [],
      source: "tenancy_guard"
    )
  end

  # pg_class is a catalog, so it is NOT RLS-filtered — which is the only reason
  # this can disambiguate "saw nothing because filtered" from "saw nothing
  # because empty". An estimate is sufficient: the question is whether the
  # table is populated at all, not how many rows it holds.
  #
  # `::regclass` rather than `WHERE relname = $1`: relname is not unique across
  # schemas or relkinds, so a same-named table in another schema (or an index)
  # returns a second row, the single-row match fails, and the probe silently
  # degrades to :unknown. regclass resolves through search_path to exactly one
  # relation.
  # `$1::text::regclass`, not `$1::regclass`. Postgrex reads the latter as an
  # `oid` parameter and RAISES ArgumentError ("you tried to use a binary for an
  # oid type") instead of returning `{:error, _}` — which the probe's error
  # handling would never have caught, because it only handles error tuples.
  # The explicit ::text pins the parameter as text and lets Postgres do the
  # lookup.
  defp estimate_rows(table) when is_atom(table) do
    Engram.Repo.query("SELECT reltuples FROM pg_class WHERE oid = $1::text::regclass", [
      to_string(table)
    ])
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
    # Not a warning even on SaaS. It is the documented state of prod today
    # (connecting as the migrator role), and the remedy is an infra change, not
    # an app one. Logged at info so a deploy can be checked against it.
    Logger.info(
      "RLS NOT enforced: the connecting role bypasses row security",
      Metadata.with_category(:info, :boot, [])
    )
  end
end
