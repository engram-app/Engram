defmodule Engram.Repo.Migrations.AddBasenameHmacExpand do
  use Ecto.Migration

  # phase/expand — nullable columns, no backfill here (Oban backfill, Task 8).
  # WHY. HMAC of lowercased, .md/.canvas-stripped basename. Makes Obsidian-style
  # case-insensitive link resolution an indexed lookup with zero bulk decryption.
  def change do
    alter table(:notes) do
      add :basename_hmac, :binary
    end

    alter table(:attachments) do
      add :basename_hmac, :binary
    end
  end
end
