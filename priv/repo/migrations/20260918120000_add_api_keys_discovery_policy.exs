defmodule Engram.Repo.Migrations.AddApiKeysDiscoveryPolicy do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # phase/expand — adds one permissive policy. Additive and forward-compatible
  # with current main.
  #
  # WHY. `api_keys` carries FORCE ROW LEVEL SECURITY with
  # `tenant_isolation_api_keys`, keyed on `current_setting('app.current_tenant')`.
  # `Accounts.validate_api_key/1` resolves a `key_hash` to its owner, so the
  # user_id is that lookup's OUTPUT and no tenant can be set beforehand. The
  # policy filtered the row to nothing, so every API-key request 401'd with
  # `invalid_key` and plugin sync, MCP clients and scripts were all locked out.
  # Observed on staging 2026-09-18 once the app pool dropped to `engram_app`;
  # latent before that only because every environment connected as a BYPASSRLS
  # migrator. See docs/context/rls-cutover-breaks-api-key-auth.md.
  #
  # WHY THIS SHAPE. Permissive policies OR within a command and AND across
  # commands, so a `FOR SELECT` policy widens reads ONLY. INSERT still goes
  # through `tenant_isolation_api_keys`'s WITH CHECK; UPDATE and DELETE still
  # go through its USING.
  #
  # The predicate is "no tenant is set" rather than `true` deliberately. `true`
  # fixes auth just as well but surrenders read isolation entirely: code inside
  # `Repo.with_tenant/2` could then read every user's keys. This way the widened
  # read is available only on the path that genuinely has no tenant, which is
  # the authentication path and nothing else.
  #
  # `current_setting(..., true)` returns NULL when never set and '' when set to
  # '', and both mean "no tenant", hence the coalesce. The `(SELECT ...)`
  # wrapper makes the planner evaluate it once per query instead of per row,
  # matching the convention `Engram.RlsPolicyFormTest` pins on the other
  # policies.
  #
  # Verified on all four verbs. With no tenant, a discovery read sees the row.
  # With a tenant set: a cross-tenant SELECT returns 0, a foreign INSERT raises
  # 42501, and cross-tenant UPDATE/DELETE both report 0 rows.
  #
  # REJECTED ALTERNATIVES. Dropping the policy outright removes the INSERT
  # WITH CHECK, the UPDATE/DELETE USING, the `prepare_query/3` tripwire and four
  # derived lints, all to fix one filtered SELECT. A SECURITY DEFINER lookup
  # would be owned by `engram`, a superuser, and a superuser-owned definer
  # function is exempt from row security unconditionally (FORCE removes only the
  # OWNER's exemption). A second BYPASSRLS pool routes every authenticated
  # request through `MAINTENANCE_POOL_SIZE` connections (default 2) and
  # contradicts `Engram.Repo.Maintenance`'s own "never the request path" rule.
  def up do
    execute """
    CREATE POLICY api_keys_discovery ON api_keys FOR SELECT
      USING (coalesce((SELECT current_setting('app.current_tenant', true)), '') = '')
    """
  end

  # WARNING: rolling this back RESTORES THE OUTAGE. Dropping this policy makes
  # `validate_api_key/1` filter to nothing again and every API-key request 401s.
  def down do
    execute "DROP POLICY IF EXISTS api_keys_discovery ON api_keys"
  end
end
