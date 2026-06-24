defmodule Engram.Repo.Migrations.AddEmbedRetryAfterToNotesExpand do
  use Ecto.Migration

  # phase/expand — additive nullable column; no backfill (NULL = eligible now).
  # Poison-loop guard: ReconcileEmbeddings skips notes whose embed cooldown
  # hasn't elapsed, capping re-bill on permanently-failing notes.
  def change do
    alter table(:notes) do
      add :embed_retry_after, :utc_datetime_usec
    end
  end
end
