defmodule Engram.Repo.Migrations.CreateProcessedWebhookEventsExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # squawk false positives here: index on a freshly-created (empty) table cannot block anything.

  # phase/expand — new table; no backfill.
  #
  # Cross-node webhook replay dedup (#862): the ETS-backed guard was
  # node-local, so a Paddle/Clerk retry routed to the other node re-ran side
  # effects (duplicate PostHog events, subscription re-touch). Handlers are
  # state-convergent so impact was low — a unique PG row makes the dedup
  # cross-node and restart-proof. Rows are (provider, event_id) only; pruned
  # after 7 days (well past provider retry windows) by IdempotencyPrune.
  def change do
    create table(:processed_webhook_events, primary_key: false) do
      add :provider, :text, null: false, primary_key: true
      add :event_id, :text, null: false, primary_key: true
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    # Prune scan (delete where inserted_at < now() - interval '7 days').
    create index(:processed_webhook_events, [:inserted_at])

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON processed_webhook_events TO engram_app",
      "REVOKE ALL ON processed_webhook_events FROM engram_app"
    )
  end
end
