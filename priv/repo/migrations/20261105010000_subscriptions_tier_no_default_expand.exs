defmodule Engram.Repo.Migrations.SubscriptionsTierNoDefaultExpand do
  use Ecto.Migration

  @moduledoc """
  Drops `subscriptions.tier`'s `DEFAULT 'trial'`.

  The baseline gave the column a default that its own `subscriptions_tier_check`
  (`free`/`starter`/`pro`, added in 20260702150100) rejects, so any insert that
  relied on it failed the CHECK with a value nobody wrote. Nothing relies on it:
  `Engram.Billing.Subscription.changeset/2` requires `tier`, and every raw insert
  (the e2e fixtures) names it. No valid default exists either: a subscription
  row's tier comes from the Paddle price, and `free` users have no row.

  With no default, an insert that omits `tier` fails NOT NULL on the column,
  which names the real mistake. A metadata-only ALTER: no rewrite, no backfill,
  no row reads the default.
  """

  # lock_timeout first: the ALTER takes ACCESS EXCLUSIVE on subscriptions, and
  # one queued behind a long transaction would stall every tier read. A busy
  # table fails the migration (retried on next boot) instead.
  def up do
    execute "SET LOCAL lock_timeout = '5s'"
    execute "ALTER TABLE subscriptions ALTER COLUMN tier DROP DEFAULT"
  end

  # Restores the original (invalid) default so a rollback is exact.
  def down do
    execute "SET LOCAL lock_timeout = '5s'"
    execute "ALTER TABLE subscriptions ALTER COLUMN tier SET DEFAULT 'trial'"
  end
end
