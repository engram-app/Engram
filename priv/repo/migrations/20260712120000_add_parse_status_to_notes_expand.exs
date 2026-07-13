defmodule Engram.Repo.Migrations.AddParseStatusToNotesExpand do
  use Ecto.Migration

  # phase/expand: parse-status columns for frontmatter-resilience (Task 4).
  #
  # `parse_status` records whether the last ingest parsed this note's
  # frontmatter cleanly ("ok") or fell back ("degraded" etc, stamped by
  # Task 5). `parse_reason` is a jsonb blob with the structured failure
  # detail for the web/plugin UI (Task 7 serializes it). Both are plaintext:
  # they describe our own parser's behavior, not note content, so no
  # encryption/HMAC is needed.

  def change do
    alter table(:notes) do
      add :parse_status, :text, null: false, default: "ok"
      add :parse_reason, :map
    end
  end
end
