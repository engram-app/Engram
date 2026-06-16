defmodule Engram.Repo.Migrations.AddTokenCountToChunks do
  use Ecto.Migration

  # phase/expand — additive nullable column; no backfill (pre-launch, wipeable).
  def change do
    alter table(:chunks) do
      add :token_count, :bigint
    end
  end
end
