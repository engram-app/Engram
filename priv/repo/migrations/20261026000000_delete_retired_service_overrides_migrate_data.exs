defmodule Engram.Repo.Migrations.DeleteRetiredServiceOverridesMigrateData do
  use Ecto.Migration

  # phase/migrate-data: the v5 flags are the code's only behaviour now and the
  # second Qdrant cluster slot is gone, so these keys left the
  # `Engram.ServiceConfig.Overrides` allowlist. A row under one is inert (the
  # reader ignores, and logs, any key it does not allow), but no app code path
  # can clear it any more, and it would keep the ignored-row warning firing on
  # every node. An old node still serving mid-rollout reads env for these keys
  # once the row is gone; prod's env mirrors every one of them
  # (engram-infra#1599, QDRANT_ACTIVE_CLUSTER=old), so nothing flips.
  def up do
    execute("""
    DELETE FROM service_overrides WHERE key IN (
      'write_v5_layout', 'v5_payload_format', 'chunk_text_write', 'chunk_text_read',
      'vector_cache_enabled', 'embed_models_per_plan', 'note_points_cap_enabled',
      'qdrant_tenant_graph', 'qdrant_active_cluster'
    )
    """)
  end

  # Irreversible: the keys are gone from the allowlist, so a restored row
  # would be ignored anyway.
  def down, do: :ok
end
