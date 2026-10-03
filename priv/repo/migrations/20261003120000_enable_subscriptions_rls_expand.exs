defmodule Engram.Repo.Migrations.EnableSubscriptionsRlsExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # phase/expand — engram-app/Engram#1758 part 2. Brings `subscriptions` under
  # the same tenant policy as the other per-user tables, plus the two extra
  # policies it needs to stay usable.
  #
  # DO NOT MERGE before a staging rehearsal with a real Paddle webhook against
  # the enforced policy. Wrong sequencing fails SILENTLY: a cancellation or
  # renewal that cannot find its row logs `:subscription_not_found` and the
  # webhook still acks 200, so Paddle never retries.
  #
  # Code that ships with this migration (all of it already names the tenant on
  # every known-user access, from #1758 part 1):
  #   * `Billing.get_subscription_by_paddle_id/1` becomes a plain app-pool read
  #     with no tenant set, answered by `subscriptions_discovery` below. It used
  #     to hop to `Repo.maintenance()` on the web request path.
  #   * `Billing.Reconciliation` (an Oban job) keeps the maintenance pool,
  #     answered by `maintenance_all`.
  #
  # WHY DISCOVERY. The Paddle webhook carries only `paddle_subscription_id`;
  # the owning user is the OUTPUT of the lookup, so no tenant can be set first.
  # Same shape as `api_keys_discovery` (20260918120000); see that migration for
  # the full reasoning. Permissive policies OR within a command and AND across
  # commands, so a `FOR SELECT` policy widens reads only: INSERT still goes
  # through `tenant_isolation_subscriptions`'s WITH CHECK, UPDATE and DELETE
  # through its USING. The predicate is "no tenant set" rather than `true`, so
  # code inside `with_tenant/2` still cannot read another user's subscription.
  #
  # TRADEOFF. Any request-path code that forgets to set a tenant can now READ
  # every subscription (tier, status, Paddle ids, period end) instead of
  # getting zero rows. It cannot write them. The app-level `prepare_query/3`
  # tripwire still rejects such a query unless `cross_tenant/1` or
  # `skip_tenant_check` is passed. Accepted over a BYPASSRLS second pool on the
  # request path, which contradicts `Engram.Repo.Maintenance`.
  #
  # `maintenance_all` is required by `Engram.Repo.MaintenanceRoleTest` for every
  # tenant table.
  #
  # Rolling deploy: nodes running the previous release read through the
  # maintenance pool for discovery (works under `maintenance_all`) and already
  # scope every other access, so old and new code both work against the
  # enforced table.
  def up do
    execute "ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE subscriptions FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY tenant_isolation_subscriptions ON subscriptions
      USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))
      WITH CHECK (user_id::text = (SELECT current_setting('app.current_tenant', true)))
    """

    execute """
    CREATE POLICY subscriptions_discovery ON subscriptions FOR SELECT
      USING (coalesce((SELECT current_setting('app.current_tenant', true)), '') = '')
    """

    execute """
    CREATE POLICY maintenance_all ON subscriptions TO engram_maintenance
      USING (true) WITH CHECK (true)
    """
  end

  # WARNING: do not roll back only part of this. Dropping JUST
  # `subscriptions_discovery` while RLS stays on makes every Paddle webhook miss
  # its row, log `:subscription_not_found`, and still ack 200, so renewals and
  # cancellations are silently lost. Dropping every policy and disabling RLS
  # together, as below, is safe for the app (back to the pre-#1758 state).
  def down do
    execute "DROP POLICY IF EXISTS maintenance_all ON subscriptions"
    execute "DROP POLICY IF EXISTS subscriptions_discovery ON subscriptions"
    execute "DROP POLICY IF EXISTS tenant_isolation_subscriptions ON subscriptions"
    execute "ALTER TABLE subscriptions NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE subscriptions DISABLE ROW LEVEL SECURITY"
  end
end
