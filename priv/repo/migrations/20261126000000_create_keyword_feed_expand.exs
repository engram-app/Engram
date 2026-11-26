defmodule Engram.Repo.Migrations.CreateKeywordFeedExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # New, empty tables only: no rows, no writers, so the concurrent-index rule
  # is moot (same reasoning as chunk_points).
  #
  # phase/expand: new tables, no backfill. Nothing writes them until the
  # Tantivy keyword store (`Engram.KeywordStore.Tantivy`) is configured; the
  # default backend (QdrantSparse, every self-host) never does.
  #
  # The transactional outbox the kwsearch service reads (search storage
  # roadmap R3, P2), its durable deletion log and the trim horizon:
  #
  #   * keyword_feed: one row per keyword op, written in the SAME transaction
  #     as the chunk rows it mirrors. `xid` is the writing transaction's id:
  #     the reader takes rows below its snapshot's xmin only, ordered by
  #     (xid, seq), because a bigserial is not commit-ordered. `user_id` has
  #     NO foreign key: a delete_user row must outlive the user until applied.
  #     Trimmed minutes after kwsearch applies it, 48 h at most
  #     (`Engram.Workers.TrimKeywordFeed`).
  #   * keyword_deletions: note, vault and user deletes only (no terms, no
  #     point lists), kept past the index snapshot retention, so a restored
  #     snapshot re-applies every later delete before it serves.
  #   * keyword_feed_horizon: one row, the highest (xid, seq) the trim deleted
  #     before kwsearch applied it. kwsearch past that point has a gap.
  #
  # The kwsearch_feed reader role and its SELECT policies are NOT here: they
  # exist only where the Tantivy backend is configured (`Engram.Release`).
  @tenant_policy "user_id = (SELECT NULLIF((SELECT current_setting('app.current_tenant', true)), '')::uuid)"

  def change do
    create table(:keyword_feed, primary_key: false) do
      add :seq, :bigserial, primary_key: true
      add :xid, :xid8, null: false, default: fragment("pg_current_xact_id()")
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
      add :user_id, :uuid, null: false
      add :vault_id, :uuid
      add :note_id, :uuid
      add :point_id, :uuid
      add :stamp, :bigint, null: false, default: 0
      add :index_set, :smallint, null: false, default: 1
      add :op, :smallint, null: false
      add :terms, :binary
      add :keep, {:array, :uuid}
    end

    create index(:keyword_feed, [:xid, :seq])
    create index(:keyword_feed, [:inserted_at])

    create table(:keyword_deletions, primary_key: false) do
      add :seq, :bigserial, primary_key: true
      add :xid, :xid8, null: false, default: fragment("pg_current_xact_id()")
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
      add :user_id, :uuid, null: false
      add :vault_id, :uuid
      add :note_id, :uuid
      add :op, :smallint, null: false
    end

    create index(:keyword_deletions, [:xid, :seq])
    create index(:keyword_deletions, [:inserted_at])

    create table(:keyword_feed_horizon, primary_key: false) do
      add :id, :smallint, primary_key: true
      add :xid, :xid8, null: false
      add :seq, :bigint, null: false
      add :updated_at, :timestamptz, null: false, default: fragment("now()")
    end

    create constraint(:keyword_feed_horizon, :keyword_feed_horizon_one_row, check: "id = 1")

    # Per-note keyword op stamp: taken under the note's row lock in every
    # note-scoped keyword transaction, so a note's stamps rise in commit order.
    execute(
      "CREATE SEQUENCE keyword_stamp_seq AS bigint",
      "DROP SEQUENCE IF EXISTS keyword_stamp_seq"
    )

    for table <- ~w(keyword_feed keyword_deletions) do
      execute(
        "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY",
        "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
      )

      execute(
        "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY",
        "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
      )

      execute(
        "CREATE POLICY tenant_isolation_#{table} ON #{table} USING (#{@tenant_policy}) WITH CHECK (#{@tenant_policy})",
        "DROP POLICY IF EXISTS tenant_isolation_#{table} ON #{table}"
      )

      execute(
        "CREATE POLICY maintenance_all ON #{table} TO engram_maintenance USING (true) WITH CHECK (true)",
        "DROP POLICY IF EXISTS maintenance_all ON #{table}"
      )

      execute(
        "GRANT SELECT, INSERT, UPDATE, DELETE ON #{table} TO engram_app",
        "REVOKE ALL ON #{table} FROM engram_app"
      )
    end

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON keyword_feed_horizon TO engram_app",
      "REVOKE ALL ON keyword_feed_horizon FROM engram_app"
    )
  end
end
