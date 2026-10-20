defmodule Engram.Repo.Migrations.AddNotesFlatFieldsExpand do
  use Ecto.Migration

  # phase/expand: nullable columns, no default, no backfill. The v5 indexing
  # pass fills them (the version stamp and reconcile reach every note), so no
  # operator action is needed.
  #
  # The v5 first-class frontmatter fields (spec 3.3b), Postgres being the
  # source of truth and the Qdrant payload a derived copy. Exact keys get a
  # full 32-byte HMAC blind index under the per-user filter key plus the value
  # encrypted under the DEK, AAD `aad_for_row(:notes, <field>, id)`. `type` and
  # `tags` already have theirs (`type_hmac`, `tags_hmac`), `created` has
  # `fm_created`. Dates are plaintext unix seconds and `priority` a plaintext
  # float, extending the 2026-07-02 rule that dates are the only plaintext
  # frontmatter. NULL means the key is absent.
  def change do
    alter table(:notes) do
      add :status_hmac, :binary
      add :status_ciphertext, :binary
      add :status_nonce, :binary
      add :author_hmac, :binary
      add :author_ciphertext, :binary
      add :author_nonce, :binary
      add :rev_by_hmac, :binary
      add :reviewed_by_ciphertext, :binary
      add :reviewed_by_nonce, :binary
      add :src_hmac, {:array, :binary}
      # A JSON list, encrypted whole.
      add :source_ciphertext, :binary
      add :source_nonce, :binary
      add :proj_hmac, :binary
      add :project_ciphertext, :binary
      add :project_nonce, :binary
      add :fm_updated, :bigint
      add :fm_reviewed, :bigint
      add :fm_expires, :bigint
      add :fm_due, :bigint
      add :fm_priority, :float
    end
  end
end
