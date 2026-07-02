defmodule Engram.Repo.Migrations.SubscriptionsCheckConstraintsExpand do
  use Ecto.Migration

  # phase/expand-shaped hardening (2026-07-02 audit, #863) — carried on a
  # phase/contract PR together with 20260702150000; the label reflects the
  # index drops.
  #
  # subscriptions.tier/status previously relied on app-side
  # validate_inclusion only — webhook-driven writes are exactly where a
  # surprising vendor value can slip in. Value sets mirror
  # Engram.Billing.Subscription.changeset/2.
  #
  # Runs inside the normal migration transaction (unlike the index drops),
  # so a VALIDATE failure rolls the whole thing back atomically — no
  # half-applied constraint state, safe to re-run.
  def up do
    execute("""
    ALTER TABLE subscriptions ADD CONSTRAINT subscriptions_tier_check
      CHECK (tier IN ('free','starter','pro')) NOT VALID
    """)

    execute("ALTER TABLE subscriptions VALIDATE CONSTRAINT subscriptions_tier_check")

    execute("""
    ALTER TABLE subscriptions ADD CONSTRAINT subscriptions_status_check
      CHECK (status IN ('trialing','active','past_due','paused','canceled')) NOT VALID
    """)

    execute("ALTER TABLE subscriptions VALIDATE CONSTRAINT subscriptions_status_check")
  end

  def down do
    execute("ALTER TABLE subscriptions DROP CONSTRAINT IF EXISTS subscriptions_status_check")
    execute("ALTER TABLE subscriptions DROP CONSTRAINT IF EXISTS subscriptions_tier_check")
  end
end
