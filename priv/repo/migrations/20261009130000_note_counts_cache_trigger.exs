defmodule Engram.Repo.Migrations.NoteCountsCacheTrigger do
  use Ecto.Migration

  @moduledoc """
  pg_notify('note_counts_changed', user_id) when a notes or attachments row
  enters or leaves what the `:note_counts` cache counts (Engram.Cache.Registry),
  so every node evicts that user's counts on commit, for EVERY writer
  including raw SQL. Same pattern as 20261009120000_cache_eviction_triggers.
  Purely additive, and re-runnable (CREATE OR REPLACE).

  Content writes (version, seq, content, crdt state) do NOT notify: every
  keystroke checkpoint updates a notes row, and none of them changes a count.
  Postgres folds identical notifications within one transaction, so a bulk
  insert notifies once per user.
  """

  @counted %{
    "notes" => ~w(user_id vault_id deleted_at kind path_hmac),
    "attachments" => ~w(user_id vault_id deleted_at)
  }

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION notify_note_counts_changed() RETURNS trigger AS $$
    BEGIN
      PERFORM pg_notify('note_counts_changed', (COALESCE(NEW.user_id, OLD.user_id))::text);
      RETURN COALESCE(NEW, OLD);
    END;
    $$ LANGUAGE plpgsql
    -- Pinned search_path (splinter: function_search_path_mutable); the body
    -- only touches pg_catalog builtins.
    SET search_path = '';
    """)

    for {table, cols} <- @counted do
      changed = Enum.map_join(cols, " OR ", &"OLD.#{&1} IS DISTINCT FROM NEW.#{&1}")

      execute("""
      CREATE OR REPLACE TRIGGER #{table}_note_counts_notify_0
      AFTER INSERT OR DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION notify_note_counts_changed();
      """)

      execute("""
      CREATE OR REPLACE TRIGGER #{table}_note_counts_notify_1
      AFTER UPDATE ON #{table}
      FOR EACH ROW WHEN (#{changed})
      EXECUTE FUNCTION notify_note_counts_changed();
      """)
    end
  end

  def down do
    for {table, _} <- @counted,
        i <- 0..1,
        do: execute("DROP TRIGGER IF EXISTS #{table}_note_counts_notify_#{i} ON #{table};")

    execute("DROP FUNCTION IF EXISTS notify_note_counts_changed();")
  end
end
