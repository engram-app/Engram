defmodule Engram.Repo.Migrations.DeleteSearchSemanticEnabledOverridesMigrateData do
  use Ecto.Migration

  # `search_semantic_enabled` left the `LimitKeys` catalog when semantic search
  # became every tier's. A row under it is inert — the resolver looks keys up
  # by name and nothing reads this one — but it would sit in admin views
  # claiming a grant or a restriction that no longer exists, and
  # `UserLimitOverride.changeset/2` now rejects the key, so no app code path
  # can edit or delete it. `user_limit_overrides` is not a tenant table, so no
  # FORCE RLS dance is needed (see the 20260831 translate migration).
  def up do
    execute("DELETE FROM user_limit_overrides WHERE key = 'search_semantic_enabled'")
  end

  # Irreversible: the key is gone from the catalog, so a restored row would be
  # unreadable anyway.
  def down, do: :ok
end
