defmodule Engram.Repo.Migrations.AddModelToRebuildManifestExpand do
  @moduledoc """
  phase/expand. `rebuild_manifest.model`: the owner's plan doc model when the
  dry run planned the note (`Engram.EmbedModels`), so the seal prices each
  note at its model's rate (Free voyage-4-lite). NULL prices as
  voyage-4-large.

  Nullable add only: metadata-only, no rewrite, no default.
  """
  use Ecto.Migration

  def change do
    alter table(:rebuild_manifest) do
      add :model, :text
    end
  end
end
