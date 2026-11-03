defmodule Engram.DataMigrations.NoteSizes do
  @moduledoc """
  Fills the stored-size columns of `note_index_state` (migration
  20261103000000) for notes written before the `notes_sync_sizes` trigger
  existed. Every later write fills them itself, from any release's code, so
  this only catches up; it is not re-verified.

  Done means `CrdtBloatSweep` may read the narrow table instead of
  aggregating `notes`. A note with no state row (the `NoteIndexState` ledger
  fills those) keeps this open, so the sweep never reads a partial table.
  Discovery walks `notes` in id windows (`Engram.Backfill.IdWindows`).
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.Backfill.IdWindows
  alias Engram.Notes.Note

  @batch 1_000

  @impl true
  def name, do: "note_sizes"

  @impl true
  def version, do: 1

  @doc """
  Live notes per vault: `%{vault_id, n, bytes}`, `bytes` the stored content
  ciphertext (tag included, as `NoteBody.byte_length(:content)`). From the
  narrow `note_index_state` once this ledger is done, else the wide `notes`
  heap. The first binding has `vault_id`, so a caller can narrow it by vault.
  """
  @spec live_totals_by_vault() :: Ecto.Query.t()
  def live_totals_by_vault do
    if done?() do
      from(s in Engram.Notes.NoteIndexState,
        where: s.note_live,
        group_by: s.vault_id,
        select: %{
          vault_id: s.vault_id,
          n: count(),
          bytes: sum(s.content_bytes + ^Engram.Crypto.Envelope.tag_bytes())
        }
      )
    else
      from(n in Note,
        where: is_nil(n.deleted_at) and n.kind == "note",
        group_by: n.vault_id,
        select: %{vault_id: n.vault_id, n: count(n.id)}
      )
      |> Engram.Notes.NoteBody.join()
      |> select_merge(^%{bytes: dynamic([n], sum(^Engram.Notes.NoteBody.byte_length(:content)))})
    end
  end

  @doc "True once every note's size columns are filled."
  @spec done?() :: boolean()
  def done?, do: Engram.DataMigrations.done?(name(), version())

  @impl true
  def run_pass, do: run_pass([])

  @doc false
  def run_pass(opts) do
    IdWindows.heal_pass(name(), Note, &heal/2, batch_size: Keyword.get(opts, :batch, @batch))
  end

  # Sizes from `note_bodies` (`nonce field (13) || ciphertext`, less the
  # 16-byte tag), as the triggers compute them; liveness from `notes`.
  # A note with no body row yet is left (NoteSplit's to fill) and keeps this open.
  # One window: fill the unfilled state rows (locked rows skipped, a later
  # pass takes them), then look for a note still unfilled or with no state row.
  defp heal(ids, %{repo: repo}) do
    keys = Enum.map(ids, &Ecto.UUID.dump!/1)

    %{num_rows: filled} =
      repo.query!(
        """
        WITH locked AS (
          SELECT note_id FROM note_index_state
          WHERE note_id = ANY($1::uuid[]) AND content_bytes IS NULL
          ORDER BY note_id FOR UPDATE SKIP LOCKED)
        UPDATE note_index_state s SET
          content_bytes = note_body_payload_bytes(b.content_ct),
          state_bytes = note_body_payload_bytes(b.crdt_ct),
          has_state = b.crdt_ct IS NOT NULL,
          note_live = n.deleted_at IS NULL,
          note_version = n.version,
          note_updated_at = n.updated_at
        FROM notes n, note_bodies b, locked l
        WHERE n.id = s.note_id AND b.note_id = s.note_id AND l.note_id = s.note_id
          AND n.kind = 'note'
        """,
        [keys]
      )

    %{rows: [[left?]]} =
      repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM notes n LEFT JOIN note_index_state s ON s.note_id = n.id
          WHERE n.id = ANY($1::uuid[]) AND n.kind = 'note'
            AND (s.note_id IS NULL OR s.content_bytes IS NULL))
        """,
        [keys]
      )

    {filled, left?}
  end
end
