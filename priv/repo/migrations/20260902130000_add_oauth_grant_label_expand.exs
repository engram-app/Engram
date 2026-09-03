defmodule Engram.Repo.Migrations.AddOauthGrantLabelExpand do
  use Ecto.Migration

  # phase/expand — nullable text add, no default, no backfill. The connections
  # list falls back to the OAuth client's own identity when it is NULL, which
  # is exactly today's behaviour, so existing grants need no data migration.
  #
  # `:text`, not `varchar(120)`: the 120-char bound is enforced in
  # `Engram.OAuth.resolve_label/1`, which REJECTS an over-long label through
  # the consent screen's access_denied path. A column bound would only add a
  # second, worse failure mode — Postgres counts code points while
  # `String.length/1` counts graphemes, so a legal 120-grapheme label can
  # exceed the column and blow up as a 500 instead of a clean rejection.
  def change do
    alter table(:oauth_authorization_codes) do
      add :label, :text
    end

    alter table(:oauth_refresh_tokens) do
      add :label, :text
    end
  end
end
