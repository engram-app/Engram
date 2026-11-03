defmodule Engram.DataMigrations.NoteSizes do
  @moduledoc """
  Fills `note_bodies.content_bytes` / `state_bytes` and
  `note_index_state.note_live` (migration 20261103000000) for rows written
  before their triggers existed. Every later write fills them itself, from
  any release's code, in the row it writes, so this only catches up (one row
  version per unfilled row, once); it is not re-verified.

  Done means `CrdtBloatSweep`, the snapshot, the PostHog sync and the budget
  sweep may read the narrow columns instead of aggregating `notes`. A note
  with no state or body row (their own ledgers fill those) keeps this open,
  so no reader sees a partial table.
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
        join: b in Engram.Notes.NoteBody,
        on: b.note_id == s.note_id,
        where: s.note_live,
        group_by: s.vault_id,
        select: %{
          vault_id: s.vault_id,
          n: count(),
          bytes: sum(b.content_bytes + ^Engram.Crypto.Envelope.tag_bytes())
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

    # Touching `content_ct` fires the `note_bodies_sizes` BEFORE trigger: the
    # sizes come from the same function as every new write. One row version
    # per unfilled body, once. Locked rows are skipped; a later pass takes them.
    %{num_rows: bodies} =
      repo.query!(
        """
        UPDATE note_bodies SET content_ct = content_ct
        WHERE note_id = ANY(ARRAY(
          SELECT note_id FROM note_bodies
          WHERE note_id = ANY($1::uuid[]) AND content_bytes IS NULL AND content_ct IS NOT NULL
          ORDER BY note_id FOR UPDATE SKIP LOCKED))
        """,
        [keys]
      )

    %{num_rows: states} =
      repo.query!(
        """
        UPDATE note_index_state s SET note_live = n.deleted_at IS NULL
        FROM notes n
        WHERE n.id = s.note_id AND s.note_id = ANY(ARRAY(
          SELECT note_id FROM note_index_state
          WHERE note_id = ANY($1::uuid[]) AND note_live IS NULL
          ORDER BY note_id FOR UPDATE SKIP LOCKED))
        """,
        [keys]
      )

    %{rows: [[left?]]} =
      repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM notes n
          LEFT JOIN note_index_state s ON s.note_id = n.id
          LEFT JOIN note_bodies b ON b.note_id = n.id
          WHERE n.id = ANY($1::uuid[]) AND n.kind = 'note'
            AND (s.note_id IS NULL OR s.note_live IS NULL OR b.note_id IS NULL
                 OR (b.content_bytes IS NULL AND b.content_ct IS NOT NULL)))
        """,
        [keys]
      )

    {bodies + states, left?}
  end
end
