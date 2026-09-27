# squawk-ignore-file — ban-drop-not-null is the point of this migration:
# `vaults.slug` goes nullable so the migrate-data release can stop writing the
# plaintext slug (slug_hmac replaces it). No client breaks: every deployed
# release, including this one, still writes `slug` on insert and rename, so no
# NULL appears until the migrate-data release, whose readers derive the slug.
# Kept in its own file because the ignore marker is file-wide; the column adds
# in 20260926100000 stay linted.
defmodule Engram.Repo.Migrations.DropVaultsSlugNotNullExpand do
  use Ecto.Migration

  # Raw SQL: Ecto's `modify` also emits `ALTER COLUMN ... TYPE`, which squawk
  # (rightly) flags as a potential rewrite. Only the constraint changes here.
  def up, do: execute("ALTER TABLE vaults ALTER COLUMN slug DROP NOT NULL")

  def down, do: execute("ALTER TABLE vaults ALTER COLUMN slug SET NOT NULL")
end
