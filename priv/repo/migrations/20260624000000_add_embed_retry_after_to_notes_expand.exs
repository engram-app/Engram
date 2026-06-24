defmodule Engram.Repo.Migrations.AddEmbedRetryAfterToNotesExpand do
  use Ecto.Migration

  # phase/expand — additive nullable column; no backfill (NULL = eligible now).
  # Poison-loop guard: ReconcileEmbeddings skips notes whose embed cooldown
  # hasn't elapsed, capping re-bill on permanently-failing notes.
  def change do
    alter table(:notes) do
      # :timestamptz (not :utc_datetime_usec, which renders bare `timestamp`)
      # to satisfy Squawk's prefer-timestamp-tz rule. The schema field stays
      # :utc_datetime_usec — Ecto reads timestamptz as a UTC DateTime.
      add :embed_retry_after, :timestamptz
    end
  end
end
