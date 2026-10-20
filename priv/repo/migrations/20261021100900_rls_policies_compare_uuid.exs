defmodule Engram.Repo.Migrations.RlsPoliciesCompareUuid do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # tenant_isolation_<table> compared `(user_id)::text = (SELECT
  # current_setting(...))`: uuid_out on every row the policy looks at, and a
  # predicate no index can serve. Now the setting is cast once per statement
  # (the initplan) and compared as a uuid. Same rows for every value the app
  # sets (`Repo.with_tenant/2` only sets a cast canonical uuid, its exit and
  # unset leave '' or NULL, both matching nothing as before). A value that is
  # not a uuid now raises instead of matching nothing: fail closed.
  # maintenance_all and the *_discovery policies do not read user_id and are
  # unchanged. RlsPolicyFormTest pins the shape; the RLS test suite the rows.
  #
  # ALTER POLICY locks its table ACCESS EXCLUSIVE, briefly. One table per
  # statement outside a transaction, so no lock is held past its own change,
  # and lock_timeout makes a busy table fail the migration (retried on the
  # next boot, every statement idempotent) instead of queueing its writers.
  @tables ~w(notes chunks attachments api_keys vaults user_agreements onboarding_actions
             crdt_update_log note_links vault_index_states vault_index_update_log
             account_exports note_revisions subscriptions)

  @uuid "user_id = (SELECT NULLIF(current_setting('app.current_tenant', true), '')::uuid)"
  @text "(user_id)::text = (SELECT current_setting('app.current_tenant', true))"

  def up, do: alter(@uuid)
  def down, do: alter(@text)

  defp alter(expr) do
    execute "SET lock_timeout = '5s'"

    for t <- @tables do
      execute "ALTER POLICY tenant_isolation_#{t} ON #{t} USING (#{expr}) WITH CHECK (#{expr})"
    end

    execute "RESET lock_timeout"
  end
end
