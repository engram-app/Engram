defmodule Engram.Repo.Migrations.AddKeywordVersionToNotesExpand do
  use Ecto.Migration

  @moduledoc """
  Records which keyword encoding built a note's sparse (BM25) vectors, so a
  keyword-only change heals existing notes with no operator step.

  #1615 changed WHAT the keyword leg encodes (the title/folder/heading prefix).
  Chunk reuse keys on the `context_text` fingerprint, which that change did not
  alter, so untouched notes kept their old vectors until someone ran
  `ReindexKeyword :sparse` by hand per vault, on SaaS and on every self-host
  install. `ReconcileEmbeddings` now selects notes whose stamp is behind
  `Engram.KeywordIndex.version/0` and rebuilds just their keyword vectors
  (`RefreshKeywordVectors`): no embedder call, no Voyage spend.

  Not backfilled, like `chunker_version` (#1620): NULL means "built before this
  stamp", which is exactly the set that needs the rebuild. No tenant-table DML,
  so none of the FORCE RLS handling (`docs/context/migrations-force-rls-data-dml.md`).
  """

  def up do
    alter table(:notes) do
      # `:bigint` for squawk's prefer-bigint-over-int gate (see the
      # chunker_version migration); the Ecto field stays `:integer`.
      add :keyword_version, :bigint
    end
  end

  def down do
    alter table(:notes) do
      remove :keyword_version
    end
  end
end
