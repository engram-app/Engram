defmodule Engram.DataMigrations.NoteFolderHashNull do
  @moduledoc """
  R9 release E migrate-data: sets `notes.folder_hmac` NULL on `kind = 'note'`
  rows, so the hash no new write sets (`Engram.Notes.FolderHash`) is not
  kept on old rows either. Markers keep theirs (their path identity).

  A note's hash is nulled only when its `folder_ref_id` names a live folder
  row whose `full_path_hmac` equals it: the hash is then provably redundant
  with the row. No Qdrant payload is touched (R3a stopped writing and reading
  the chunk `f`). A root note (no reference, it keeps its hash), a drift note (no
  reference or a dead one) and a note whose row disagrees are left as they
  are and do not keep the ledger open.

  Blocked (the pass walks nothing, resets its walk and stays open) while
  `NotePayloadStamps` is not done: until every point has `n`, the write stop
  is off too (`FolderHash.write?/0`). A ledger that reopens later blocks
  nothing already done: every reader from C on places a note by its
  reference. Older releases read the hash, which is why E needs the rollback
  floor at C.

  Discovery and writes go through `Engram.Backfill.IdWindows.heal_pass/4`
  (`notes` primary-key windows of 200; one fleet walk on the maintenance pool
  on SaaS, per tenant on self-host). Each window is one statement under
  `SET LOCAL lock_timeout = '2s'` and `statement_timeout = '5s'`, locking with
  `FOR UPDATE OF n SKIP LOCKED`: a row a writer holds is skipped and counts
  as left. Per row: one `folders` primary-key probe and one non-HOT update
  (`folder_hmac` and the `folder_id` key `notes_derive_core_keys` derives
  from it are indexed). The load that matters is autovacuum cleaning the dead
  tuples (R8's null batch, 2026-11-07), so the per-pass cap is low: the
  `note_folder_hash_null_max_fixed` service override (rows, default 2,000),
  about 2,000 dead `notes` tuples and their index entries per hourly pass.

  Kill switch: `enabled?/0` is the `note_folder_hash_null` service override
  (default on). Not re-verified: a C or D node (rollout or rollback) writes a
  correct hash, never a stale one, and that hash is harmless; a later pass of
  a new version would null it.
  """
  @behaviour Engram.DataMigration

  alias Engram.Backfill.IdWindows
  alias Engram.DataMigrations.NotePayloadStamps
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note

  require Logger

  @batch 200
  @max_fixed 2_000

  @impl true
  def name, do: "note_folder_hash_null"

  @impl true
  def version, do: 1

  @doc """
  Kill switch: the `note_folder_hash_null` service override (default on).
  Off, the runner runs no pass and the ledger stays open.
  """
  @impl true
  def enabled?, do: Engram.ServiceConfig.get(:note_folder_hash_null, true) == true

  @impl true
  def run_pass, do: run_pass([])

  @doc false
  # `batch:` / `max_fixed:` override the window size and per-pass cap.
  def run_pass(opts) do
    case blocker() do
      nil -> walk(opts)
      reason -> blocked(reason)
    end
  end

  @doc false
  # The guard that fails, or nil.
  def blocker, do: if(NotePayloadStamps.done?(), do: nil, else: :note_payload_stamps_open)

  defp blocked(reason) do
    IdWindows.reset_walk(name())
    :ok = Engram.DataMigration.report(blocked: reason)
    {:more, rows: 0, blocked: 1}
  end

  defp walk(opts) do
    IdWindows.heal_pass(name(), Note, &null/2,
      batch_size: Keyword.get(opts, :batch, @batch),
      max_fixed: Keyword.get_lazy(opts, :max_fixed, &max_fixed/0)
    )
  end

  @doc false
  # The per-pass cap: the service override when it is a positive integer,
  # else the default, with a warning.
  def max_fixed do
    case Engram.ServiceConfig.get(:note_folder_hash_null_max_fixed, @max_fixed) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        Logger.warning(
          "note_folder_hash_null_max_fixed is not a positive integer, using #{@max_fixed}",
          Metadata.with_category(:warning, :data)
        )

        @max_fixed
    end
  end

  # A note whose live folder row holds the same hash. `n` the note, `f` its
  # folder row, probed by primary key.
  @redundant """
  n.id = ANY($1) AND n.kind = 'note' AND n.folder_hmac IS NOT NULL
    AND f.id = n.folder_ref_id AND f.deleted_at IS NULL AND f.full_path_hmac = n.folder_hmac
  """

  # Lock the window's redundant rows (skipping a row a writer holds) in a
  # MATERIALIZED CTE, evaluated once (`NoteSplit.touch/2` explains why a
  # rescanned LIMIT .. SKIP LOCKED subquery is wrong), then null them.
  @null_sql """
  WITH c AS MATERIALIZED (
    SELECT n.id FROM notes AS n, folders AS f
    WHERE #{@redundant}
    ORDER BY n.id
    FOR UPDATE OF n SKIP LOCKED
  )
  UPDATE notes AS n SET folder_hmac = NULL
  FROM c
  WHERE n.id = c.id
  """

  # What is left in a window: a redundant hash a held lock skipped.
  @left_sql "SELECT count(*)::int FROM notes AS n, folders AS f WHERE #{@redundant}"

  @doc false
  def null_sql, do: @null_sql

  defp null(ids, %{repo: repo}) do
    ids = Enum.map(ids, &Ecto.UUID.dump!/1)
    _ = repo.query!("SET LOCAL lock_timeout = '2s'", [])
    _ = repo.query!("SET LOCAL statement_timeout = '5s'", [])
    %{num_rows: fixed} = repo.query!(@null_sql, [ids])
    %{rows: [[left]]} = repo.query!(@left_sql, [ids])
    {fixed, left > 0}
  end
end
