defmodule Engram.Repo.Migrations.NotesNameKeyEitherAnchorExpand do
  use Ecto.Migration

  @moduledoc """
  phase/expand, release L (retiring `notes.path_*`): `notes_set_name_key`
  (20261113100000) trusts a note's name keys when `name_stamp` is anchored
  on EITHER nonce: `path_nonce || '\\x01'` (every stamp written today) or
  `name_nonce || '\\x01'` (the anchor a later release re-stamps onto, so
  `path_nonce` can stop being written). `Engram.Crypto.NameKeys.current?/3`
  and `Engram.Notes.Location.derivable?/1` say the same in Elixir.

  Function body only: the trigger and its `UPDATE OF` column list are
  unchanged, so this takes no lock on `notes` (CREATE OR REPLACE FUNCTION
  locks only the function) and cannot queue or fail on a busy table. Every
  writer of `name_nonce` writes `name_stamp` in the same statement
  (`Engram.Notes.Name.keys/6`), and `name_stamp` is in the column list, so
  the trigger still fires on every re-anchor. Nothing is restamped here.

  Rollback-safe: the previous release writes path-anchored stamps only,
  which both bodies accept. `down` restores 20261113100000's body.
  """

  def up,
    do:
      execute(
        function("""
               AND (NEW.name_stamp = NEW.path_nonce || '\\x01'::bytea
                    OR NEW.name_stamp = NEW.name_nonce || '\\x01'::bytea)
        """)
      )

  def down,
    do: execute(function("       AND NEW.name_stamp = NEW.path_nonce || '\\x01'::bytea\n"))

  defp function(anchor) do
    """
    CREATE OR REPLACE FUNCTION notes_set_name_key() RETURNS trigger
    LANGUAGE plpgsql SET search_path = '' AS $$
    BEGIN
      NEW.name_key := CASE
        WHEN NEW.kind = 'note' AND NEW.folder_ref_id IS NOT NULL
             AND NEW.name_ci_hmac IS NOT NULL
    #{anchor}    THEN NEW.name_ci_hmac || uuid_send(NEW.folder_ref_id)
      END;
      RETURN NEW;
    END
    $$
    """
  end
end
