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
  answer. Hence one query at boot:

      SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user

  That is also the only honest way to tell the two deployments apart without
  adding a flag someone has to remember to set. A flag would have exactly the
  failure mode this guard exists to catch.

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

  @doc """
  `true` when the connecting role is subject to RLS.

  Inverted from what the query asks: a role that is `rolsuper` or
  `rolbypassrls` reads every row regardless of policy, so enforcement is OFF
  for it. Anything else is enforced.
  """
  @spec enforced?() :: boolean()
  def enforced? do
    case Engram.Repo.query!(
           "SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user",
           [],
           source: "tenancy_guard"
         ) do
      %{rows: [[bypasses?]]} -> not bypasses?
      # No row for current_user should be impossible. Treat the unknown as
      # "enforced" so the noisy branch is the one that fires: a false alarm
      # costs a log line, the other direction hides the bug.
      _ -> true
    end
  end

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [])
  end

  @impl true
  def init(_) do
    report(enforced?(), Engram.Repo.maintenance() != Engram.Repo)
    :ignore
  end

  defp report(true = _enforced?, false = _maintenance_pool?) do
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

  defp report(true = _enforced?, true = _maintenance_pool?) do
    Logger.info(
      "RLS enforced; maintenance pool configured",
      Metadata.with_category(:info, :boot, [])
    )
  end

  defp report(false = _enforced?, _maintenance_pool?) do
    # Not a warning even on SaaS. It is the documented state of prod today
    # (connecting as the migrator role), and the remedy is an infra change, not
    # an app one. Logged at info so a deploy can be checked against it.
    Logger.info(
      "RLS NOT enforced: the connecting role bypasses row security",
      Metadata.with_category(:info, :boot, [])
    )
  end
end
