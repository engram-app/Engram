defmodule Engram.Repo.Migrations.CreateIdempotencyKeysExpand do
  use Ecto.Migration

  # phase/expand — new table; no backfill.
  #
  # Replaces the node-local ETS idempotency cache for batch endpoints (#862):
  # under clustering, a client retry routed to the other node missed the ETS
  # entry and re-executed the batch — the idempotency key was defeated by the
  # LB. Rows are also user-scoped (the ETS cache was keyed globally) and the
  # cached response body is DEK-encrypted + AAD-bound to (user, key), because
  # batch responses carry plaintext note paths.
  #
  # No RLS (rls_coverage allowlist): every read/write filters user_id
  # app-side, the payload is ciphertext under the tenant's own DEK, and the
  # expiry pruner needs cheap cross-tenant deletes.
  def change do
    create table(:idempotency_keys, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :key, :uuid, null: false
      add :status, :integer, null: false
      add :response_ciphertext, :binary, null: false
      add :response_nonce, :binary, null: false
      add :expires_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    # Replay lookup key; unique so concurrent duplicate remembers race to one
    # row (ON CONFLICT DO NOTHING — first response wins).
    create unique_index(:idempotency_keys, [:user_id, :key])
    # Expiry pruner scan.
    create index(:idempotency_keys, [:expires_at])

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON idempotency_keys TO engram_app",
      "REVOKE ALL ON idempotency_keys FROM engram_app"
    )
  end
end
