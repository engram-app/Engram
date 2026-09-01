defmodule Engram.Repo.Migrations.TranslateLegacyLimitOverridesMigrateData do
  use Ecto.Migration

  # The `@legacy_inverted_keys` alias in `Engram.Billing` resolved override rows
  # written under the restriction-shaped spellings and FLIPPED their sense.
  # Deleting that alias without touching the rows would not error — it would
  # make them inert, and inert runs in the permissive direction:
  #
  #   inactivity_warn_60_days = false   (operator suppressed dunning)
  #     -> row no longer matched; falls to inactivity_warnings_exempt default
  #        (false) -> NOT exempt -> that user starts receiving the 60- and
  #        80-day account-deletion warning emails on the next nightly sweep.
  #
  #   attachments_text_only = true      (operator restricted attachments)
  #     -> falls to attachments_all_types default (true) -> restriction lifted.
  #
  # Both fail silently and in the direction that hurts, so translate rather than
  # assume the rows do not exist. Reads never re-validate an override row, and
  # `UserLimitOverride.changeset/2` rejects the retired keys, so this is the only
  # place the repair can happen.
  #
  # `value` is jsonb shaped `{"v": <bool>}`; the sense inverts, so `v` is negated.
  # ON CONFLICT: if the operator already has a row under the new spelling, that
  # one is authoritative and the legacy row is simply dropped.

  @translations [
    {"attachments_text_only", "attachments_all_types"},
    {"inactivity_warn_60_days", "inactivity_warnings_exempt"}
  ]

  def up do
    for {legacy, current} <- @translations do
      execute("""
      INSERT INTO user_limit_overrides (user_id, key, value, reason, set_by, set_at)
      SELECT user_id,
             '#{current}',
             jsonb_build_object('v', NOT (value->>'v')::boolean),
             COALESCE(reason, '') || ' [migrated from #{legacy}]',
             set_by,
             set_at
        FROM user_limit_overrides
       WHERE key = '#{legacy}'
         AND jsonb_typeof(value->'v') = 'boolean'
      ON CONFLICT (user_id, key) DO NOTHING
      """)

      execute("DELETE FROM user_limit_overrides WHERE key = '#{legacy}'")
    end
  end

  # Irreversible by design: the forward direction is lossy where a row already
  # existed under the current spelling (ON CONFLICT DO NOTHING drops the legacy
  # one), so a rollback cannot reconstruct which rows were translated versus
  # pre-existing. The retired keys are also no longer in `LimitKeys`, so a
  # restored row would be unreadable anyway.
  def down do
    :ok
  end
end
