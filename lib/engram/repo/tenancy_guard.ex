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
      SELECT EXISTS (SELECT 1 FROM notes LIMIT 1)

  `true` means rows belonging to other tenants are reachable — bypassed, no
  matter what `pg_roles` claims. Bounded by `LIMIT 1`, run inside a rolled-back
  transaction, and it reads nothing it does not already own.

  A negative result is ambiguous on its own: an enforced connection and an
  empty table look identical. `pg_class.reltuples` disambiguates, because the
  catalog is not RLS-filtered — no visible rows against a table the planner
  believes is populated is enforcement; no visible rows against an apparently
  empty table is `:unknown`, not a clean bill of health.

  Both answers are still collected, and `report/2` says so when they diverge.
  That divergence IS #1726, and if it ever recurs it should arrive as a
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
  def enforcement do
    case observed_enforcement() do
      # The probe could not speak — an empty or never-analyzed `notes` table,
      # or a query that failed. Fall back to the attribute answer rather than
      # reporting `:unknown`, because a weak answer beats none: `:unknown`
      # makes `enforced?/0` true, which makes `OrphanSweep` refuse, and a fresh
      # self-host install with no notes yet would refuse its weekly sweep
      # forever while logging an error about it.
      #
      # This is also what preserves the old behaviour everywhere the probe
      # adds nothing, which is most of dev and CI.
      :unknown -> claimed_enforcement()
      observed -> observed
    end
  end

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

  Adopts a tenant that owns nothing and asks whether any `notes` row is
  reachable anyway. Wrapped in a transaction so `set_config/3`'s local flag has
  a scope to be local TO, and rolled back so the guard leaves no trace on the
  connection it borrowed — `set_config(..., true)` would survive to the end of
  an enclosing transaction otherwise, and this runs on a pooled connection that
  goes straight back into service.
  """
  @spec observed_enforcement() :: :enforced | :bypassed | :unknown
  def observed_enforcement do
    # `mode: :savepoint` is load-bearing, and its absence was a real bug caught
    # by the "leaves the caller's tenant untouched" test. Without it a nested
    # `Repo.transaction` joins the caller's transaction rather than opening a
    # subtransaction, so this would have torn down the transaction of whoever
    # called `enforced?/0` from inside one. `Engram.Workers.OrphanSweep` calls
    # it, which makes that a live path rather than a hypothetical.
    Engram.Repo.transaction(
      fn ->
        previous = current_tenant()

        verdict =
          with {:ok, _} <- set_tenant(@nobody),
               {:ok, %{rows: [[visible?]]}} <- probe_visibility(),
               {:ok, %{rows: [[estimated_rows]]}} <- estimate_rows() do
            verdict(visible?, estimated_rows)
          else
            _ -> :unknown
          end

        # Restore rather than roll back. Rolling back would also discard the
        # caller's work if this ever runs inside their transaction, and the
        # savepoint already covers the raise path — a raise aborts the
        # subtransaction, which reverts the SET LOCAL without our help.
        # Return deliberately discarded: `set_config` fails only if the
        # connection is already gone, in which case the savepoint is unwinding
        # anyway and there is no tenant left to restore. Bound explicitly so
        # dialyzer's unmatched_returns stays on for the rest of the module.
        _ = set_tenant(previous)

        verdict
      end,
      mode: :savepoint
    )
    |> case do
      {:ok, verdict} -> verdict
      # The transaction itself failed to open. Same class as a query error.
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

  defp probe_visibility do
    Engram.Repo.query("SELECT EXISTS (SELECT 1 FROM notes LIMIT 1)", [], source: "tenancy_guard")
  end

  # pg_class is a catalog, so it is NOT RLS-filtered — which is the only reason
  # this can disambiguate "saw nothing because filtered" from "saw nothing
  # because empty". An estimate is sufficient: the question is whether the
  # table is populated at all, not how many rows it holds.
  defp estimate_rows do
    Engram.Repo.query("SELECT reltuples FROM pg_class WHERE relname = 'notes'", [],
      source: "tenancy_guard"
    )
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

    report_divergence(observed, claimed_enforcement())
    report(observed, Engram.Repo.maintenance() != Engram.Repo)

    :ignore
  end

  # Agreement is the normal case and says nothing worth a line.
  defp report_divergence(same, same), do: :ok

  # The probe abstained, so there are not two answers to disagree. `enforcement/0`
  # has already fallen back to the attribute answer; saying "they diverge" here
  # would be reporting the absence of evidence as evidence.
  defp report_divergence(:unknown, _claimed), do: :ok

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

      The observed answer is the one everything downstream uses, because it is
      the one that describes what a query will actually return. Treat this line
      as the finding, not as noise: it means the deployment is in the state
      nobody has explained.
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
