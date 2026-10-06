defmodule Engram.Repo.Migrations.AddScopeToIdempotencyKeysExpand do
  use Ecto.Migration

  @moduledoc """
  phase/expand — two nullable columns; no backfill.

  Records the vault and route a cached batch response belongs to (#1869).
  Replay matched `(user_id, key)` only, so a credential scoped to vault B could
  replay vault A's cached response if it knew the key. `lookup` now matches
  both columns, so legacy rows (NULL) read as a miss — safe, a miss only
  re-executes an idempotent batch — and the 24h TTL prunes them.

  No FK on `vault_id`: rows live 24h and are never joined to vaults. No
  tenant-table DML (and no RLS on this table), so none of the FORCE RLS handling.
  """

  def change do
    alter table(:idempotency_keys) do
      add :vault_id, :uuid
      add :route, :text
    end
  end
end
