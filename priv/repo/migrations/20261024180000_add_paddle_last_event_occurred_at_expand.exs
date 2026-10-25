defmodule Engram.Repo.Migrations.AddPaddleLastEventOccurredAtExpand do
  use Ecto.Migration

  @moduledoc """
  `subscriptions.last_event_occurred_at`: the `occurred_at` of the newest
  Paddle `subscription.*` event applied to the row. Paddle does not guarantee
  delivery order, so `Engram.Billing.upsert_from_paddle_event/1` skips any
  event older than this value (a delayed `subscription.updated` landing after
  `subscription.canceled` would otherwise re-grant paid access).

  Nullable, no default, no backfill: NULL means "no event stamped yet", and
  the handler accepts any event against a NULL stamp, which is the old
  behaviour. A metadata-only ALTER; purely additive.
  """

  # lock_timeout first: the ALTER takes ACCESS EXCLUSIVE on subscriptions,
  # and an add queued behind a long transaction would stall every tier read.
  # A busy table fails the migration (retried on next boot) instead.
  def up do
    execute "SET LOCAL lock_timeout = '5s'"

    alter table(:subscriptions) do
      add :last_event_occurred_at, :utc_datetime_usec
    end
  end

  def down do
    execute "SET LOCAL lock_timeout = '5s'"

    alter table(:subscriptions) do
      remove :last_event_occurred_at
    end
  end
end
