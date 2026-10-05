defmodule Engram.Repo.Migrations.AddEmbedModelToNotesExpand do
  use Ecto.Migration

  @moduledoc """
  Records which embedding model built a note's dense vectors, so a model
  switch heals existing notes with no operator step.

  Vectors from different models are not comparable: after a switch (a
  self-hoster changing Ollama models, or a SaaS model upgrade), old notes would
  rank against new queries on noise. `ReconcileEmbeddings` re-embeds notes
  whose stamp differs from `Engram.Indexing.embed_model/0`, as unmetered
  maintenance (see `docs/context/index-version-self-heal.md`).

  Not backfilled: NULL means "dense vectors from before the stamp", which is
  re-embedded once. No tenant-table DML, so none of the FORCE RLS handling.
  """

  def up do
    alter table(:notes) do
      add :embed_model, :text
    end
  end

  def down do
    alter table(:notes) do
      remove :embed_model
    end
  end
end
