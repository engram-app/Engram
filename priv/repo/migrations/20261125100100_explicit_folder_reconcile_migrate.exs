# Shared helper; see the file for why it is not in lib/.
Code.require_file("lock_timeout_retry.exs", __DIR__)

defmodule Engram.Repo.Migrations.ExplicitFolderReconcileMigrate do
  @moduledoc """
  phase/migrate-data, release J (S6 step 3/4, Engram#2523): the last run of
  the `ExplicitFolderReconcile` ledger's rule, at boot, for an install whose
  ledger never closed. Clears `folders.explicit` on every live row with no
  `explicit_seq` and no live marker at its `full_path_hmac` (a deleted empty
  folder a pre-#2639 cascade left listed).

  Why at boot: release J retires the ledger and stops writing
  `full_path_hmac`, so a rename J serves leaves the hash stale and the rule
  would then clear a live folder. Boot runs before J serves, while every
  hash is still the previous release's. A self-hoster skipping from before
  the ledger closed gets the work here; an install whose ledger closed
  (prod since release D) skips the clear: the ledger's own daily re-verify
  already ran the rule against the same rows.

  Then, on every install (ledger closed or not), every live explicit row
  with no `explicit_seq` gets `explicit_seq = 0`, FolderMarkerDelete's own
  pre-delete stamp. Release I's rule skips a stamped row, and J can leave the
  hash of an unstamped one stale: a root-only rename rewrites the
  descendants' markers but not their rows' hashes, and a DEK rotation re-keys
  the markers but no longer the hashes. A self-host keeps its markers
  (`folder_marker_delete` ships off), so after a rollback to I its daily
  walk would unlist those folders and the plugin trash them. Every J writer
  that makes a row explicit stamps it too, so none is left unstamped after
  boot. Prod: expected 0 rows (the marker delete stamped them all), read on
  `folders_explicit_vault_live` (live explicit rows, far fewer than the ~47k
  folder rows).

  One statement (a DO block, atomic), so the FORCE ROW LEVEL SECURITY
  toggle cannot be left off: the tables are unforced for the owner, the
  rows cleared, the rule re-checked (raises if any row is left), the rows
  stamped, the tables forced again. ACCESS EXCLUSIVE on `folders` (and, on
  an open ledger, `notes`) for that statement, under `LockTimeoutRetry`
  (5 s `lock_timeout`, two retries). Rerun-safe. `down` restores nothing
  (the cleared flags named no folder; a stamp only keeps a folder listed).
  """
  use Ecto.Migration

  alias Engram.Repo.Migrations.LockTimeoutRetry

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Release I's `ExplicitFolderReconcile.@stale` over the whole table (its
  # scalar `(SELECT 1 ... LIMIT 1) IS NULL` written as NOT EXISTS).
  @stale """
  f.explicit AND f.explicit_seq IS NULL AND f.deleted_at IS NULL AND NOT EXISTS (
    SELECT 1 FROM notes AS n
    WHERE n.user_id = f.user_id AND n.vault_id = f.vault_id AND n.kind = 'folder'
      AND n.deleted_at IS NULL AND n.folder_hmac = f.full_path_hmac)
  """

  @reconcile """
  DO $$
  DECLARE
    left_over bigint;
  BEGIN
    ALTER TABLE folders NO FORCE ROW LEVEL SECURITY;

    IF NOT EXISTS (
      SELECT 1 FROM data_migrations
      WHERE name = 'explicit_folder_reconcile' AND completed_at IS NOT NULL
    ) THEN
      ALTER TABLE notes NO FORCE ROW LEVEL SECURITY;

      UPDATE folders AS f SET explicit = false, updated_at = now() WHERE #{@stale};

      SELECT count(*) INTO left_over FROM folders AS f WHERE #{@stale};
      IF left_over <> 0 THEN
        RAISE EXCEPTION 'explicit folder reconcile left % rows', left_over;
      END IF;

      ALTER TABLE notes FORCE ROW LEVEL SECURITY;
    END IF;

    UPDATE folders SET explicit_seq = 0
    WHERE explicit AND explicit_seq IS NULL AND deleted_at IS NULL;

    ALTER TABLE folders FORCE ROW LEVEL SECURITY;
  END
  $$
  """

  @doc false
  # The rule as a WHERE clause over `folders AS f` (tests run it as release I's walk).
  def stale, do: @stale

  @doc false
  def reconcile(repo), do: LockTimeoutRetry.with_lock_timeout(repo, [@reconcile])

  def up, do: reconcile(repo())

  def down, do: :ok
end
