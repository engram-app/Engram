defmodule Engram.DataMigrations.EffectiveDates do
  @moduledoc """
  Derives `notes.fm_updated` / `fm_created_s` / `eff_updated` /
  `eff_created` (migration 20261105150000) on every note whose `eff_v` is
  not its `version`: notes written before the columns existed, and notes a
  release without them wrote since (a rolling deploy, a rollback), which
  moved `version` past `eff_v`. Every content save of this release derives
  them itself (`Note.changeset/2`), so the work set only shrinks.

  The frontmatter dates come from `note_attrs` (the index pass's
  `updated` / `created` keys, the same `FlatFields` parser the save uses);
  the stored dates from `Engram.Notes.EffectiveDates.stored/2`. A note
  never indexed has no `note_attrs` dates and gets its file time only,
  until its next save.

  Order against the file-time migrate-data (the `mtime_at` / `ctime_at`
  backfill, not built yet): none needed. The file time is read from the
  double through `Engram.FileTime`, the function that fills `*_at`, so this
  pass gives the same value whether or not that backfill has run, and a
  previous release's write that moved the double without its `*_at` cannot
  make it stale. When the contract phase drops the doubles, `stored/2`
  switches to `*_at` and this ledger version is bumped.

  Until a row is derived, the note filter reads its row time
  (`EffectiveDates.updated_sql/1`). Not re-verified. Discovery walks `notes`
  in id windows (`Engram.Backfill.IdWindows`).
  """
  @behaviour Engram.DataMigration

  alias Engram.Backfill.IdWindows
  alias Engram.Notes.EffectiveDates
  alias Engram.Notes.FrontmatterKeys
  alias Engram.Notes.Note

  @batch 1_000
  @max_fixed 50_000

  @needs "n.kind = 'note' AND n.eff_v IS DISTINCT FROM n.version"

  @impl true
  def name, do: "note_effective_dates"

  @impl true
  def version, do: 1

  @impl true
  def run_pass, do: run_pass([])

  @doc false
  def run_pass(opts) do
    IdWindows.heal_pass(name(), Note, &heal/2,
      batch_size: Keyword.get(opts, :batch, @batch),
      max_fixed: Keyword.get(opts, :max_fixed, @max_fixed)
    )
  end

  # One window: lock the rows that need it (locked ones are skipped, a later
  # pass takes them), derive in Elixir, write them in one UPDATE. A save
  # holding the row lock wins; its version then matches its own `eff_v`.
  defp heal(ids, %{repo: repo}) do
    keys = Enum.map(ids, &Ecto.UUID.dump!/1)

    {:ok, fixed} =
      repo.transaction(fn ->
        %{rows: rows} =
          repo.query!(
            """
            SELECT n.id, n.version, n.mtime, n.ctime,
              (SELECT a.d FROM note_attrs a WHERE a.note_id = n.id AND a.key_id = $2 AND a.ord = 0),
              (SELECT a.d FROM note_attrs a WHERE a.note_id = n.id AND a.key_id = $3 AND a.ord = 0)
            FROM notes n
            WHERE n.id = ANY($1::uuid[]) AND #{@needs}
            ORDER BY n.id FOR UPDATE OF n SKIP LOCKED
            """,
            [keys, FrontmatterKeys.named_id(:updated), FrontmatterKeys.named_id(:created)]
          )

        cols = Enum.map(rows, &derive/1)

        %{num_rows: n} =
          repo.query!(
            """
            UPDATE notes SET fm_updated = v.fu, fm_created_s = v.fc,
              eff_updated = v.eu, eff_created = v.ec, eff_v = v.ver
            FROM unnest($1::uuid[], $2::bigint[], $3::bigint[], $4::bigint[], $5::bigint[],
                        $6::bigint[]) AS v(id, fu, fc, eu, ec, ver)
            WHERE notes.id = v.id
            """,
            Enum.map(0..5, fn i -> Enum.map(cols, &elem(&1, i)) end)
          )

        n
      end)

    # A row still underived was skipped as locked: the walk is not clean.
    %{rows: [[left?]]} =
      repo.query!(
        "SELECT EXISTS (SELECT 1 FROM notes n WHERE n.id = ANY($1::uuid[]) AND #{@needs})",
        [keys]
      )

    {fixed, left?}
  end

  defp derive([id, version, mtime, ctime, fm_up, fm_cr]) do
    {id, fm_up, fm_cr, EffectiveDates.stored(fm_up, mtime), EffectiveDates.stored(fm_cr, ctime),
     version}
  end
end
