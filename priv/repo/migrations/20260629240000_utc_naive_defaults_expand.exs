defmodule Engram.Repo.Migrations.UtcNaiveDefaultsExpand do
  use Ecto.Migration

  @moduledoc """
  phase/expand — metadata-only `ALTER COLUMN SET DEFAULT` (no table rewrite,
  no lock, forward-compatible).

  Three columns are `timestamp` (naive) but carry a DB-side `now()` default.
  `now()` returns `timestamptz`; coercing it into a naive column uses the
  server's TimeZone GUC, so the stored value is only UTC while the GUC is UTC.
  Pin them to `timezone('UTC', now())`, which produces a UTC-naive value
  regardless of the session timezone — the same form Oban already uses.

  Audit finding Engram#792. `user_agreements.accepted_at` is the
  compliance-relevant one (recorded ToS acceptance time). The columns stay
  naive `timestamp` (consistent with the rest); only the default changes.
  """

  def up do
    execute "ALTER TABLE usage_meters ALTER COLUMN updated_at SET DEFAULT timezone('UTC', now())"

    execute "ALTER TABLE user_agreements ALTER COLUMN accepted_at SET DEFAULT timezone('UTC', now())"

    execute "ALTER TABLE user_limit_overrides ALTER COLUMN set_at SET DEFAULT timezone('UTC', now())"
  end

  def down do
    execute "ALTER TABLE usage_meters ALTER COLUMN updated_at SET DEFAULT now()"
    execute "ALTER TABLE user_agreements ALTER COLUMN accepted_at SET DEFAULT now()"
    execute "ALTER TABLE user_limit_overrides ALTER COLUMN set_at SET DEFAULT now()"
  end
end
