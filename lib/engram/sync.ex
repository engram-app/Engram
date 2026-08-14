defmodule Engram.Sync do
  @moduledoc """
  Ordered change-log sync: builds one seq-ordered page merging the notes and
  attachments change feeds for a vault (the socket op-log catch-up feed).
  """
  alias Engram.{Attachments, Notes}

  @doc """
  One seq-ordered page merging the notes + attachments change feeds for a vault.

  `seq` is a vault-global sequence (both `Notes` and `Attachments` upserts draw
  from `Vaults.next_seq!/1`), so a note and an attachment can never share a seq —
  the merged stream is a total order and an integer cursor paginates it
  correctly. Each row is tagged `:type` (`:note` | `:attachment`) so the client
  dispatches apply per kind.

  Fetches `limit + 1` from EACH feed so the merged page can still fill `limit`
  when one feed is exhausted inside the window, then trims to `limit`. Returns
  `%{page: [...], has_more: boolean, next: {seq, id} | nil}`.

  Both feeds internally cap their page at 500 rows; callers must clamp `limit`
  to that ceiling (see `SyncController`), else a feed could return its capped 500
  (< limit) while in-range rows remain and the trim branch would be skipped —
  silently dropping rows.

  `max_bytes` bounds the note content this page may carry (see
  `Notes.list_changes_by_seq/4`). Pass `nil` to use the configured default.
  """
  def merged_changes_page(user, vault, after_seq, after_id, limit, fields, max_bytes \\ nil)
      when is_integer(after_seq) and is_integer(limit) do
    # One slot per in-flight page (see PageGate): the byte budget bounds ONE
    # page, this bounds how many exist at once so a burst of first syncs queues
    # instead of stacking memory. Queues, never rejects — the client aborts its
    # whole walk on a rejected fetch.
    Engram.Sync.PageGate.with_slot(fn ->
      build_page(user, vault, after_seq, after_id, limit, fields, max_bytes)
    end)
  end

  defp build_page(user, vault, after_seq, after_id, limit, fields, max_bytes) do
    {:ok, %{changes: notes, has_more: notes_more}} =
      Notes.list_changes_by_seq(user, vault, after_seq,
        after_id: after_id,
        limit: limit + 1,
        fields: fields,
        max_bytes: max_bytes
      )

    # Attachments carry no note content, so the `fields` projection is n/a here
    # and so is the byte budget — an attachment row is metadata only.
    {:ok, %{changes: atts, has_more: atts_more}} =
      Attachments.list_changes_by_seq(user, vault, after_seq,
        after_id: after_id,
        limit: limit + 1
      )

    merged =
      (Enum.map(notes, &Map.put(&1, :type, :note)) ++
         Enum.map(atts, &Map.put(&1, :type, :attachment)))
      |> Enum.sort_by(&key/1)

    # WATERMARK — do not emit past the point where either feed is known to be
    # incomplete.
    #
    # The two feeds are paginated independently and merged by seq. A feed that
    # reports has_more is only trustworthy up to its own last row: past that
    # point it may hold rows we did not fetch. Emitting the OTHER feed's higher
    # seqs anyway advances the shared cursor past those unfetched rows, and the
    # client resumes after them — they are skipped permanently, not delayed.
    #
    # Latent before the byte budget (both feeds truncated at the same row count,
    # so their last rows sat close together), and reachable after it: the notes
    # feed can now stop at 1 row on seq 5 while attachments still return 500 rows
    # up to seq 500. Without this clamp that page would strand every note between.
    watermark =
      [notes_more && List.last(notes), atts_more && List.last(atts)]
      |> Enum.filter(&is_map/1)
      |> Enum.map(&key/1)
      |> Enum.min(fn -> nil end)

    capped = if watermark, do: Enum.filter(merged, &(key(&1) <= watermark)), else: merged

    {page, has_more} =
      if length(capped) > limit do
        {Enum.take(capped, limit), true}
      else
        # `capped` shorter than `merged` means the watermark held rows back, so
        # there is definitionally more to serve even if neither feed said so.
        {capped, notes_more or atts_more or length(capped) < length(merged)}
      end

    next =
      if has_more and page != [] do
        last = List.last(page)
        {last.seq, last.id}
      end

    %{page: page, has_more: has_more, next: next}
  end

  defp key(row), do: {row.seq, row.id}
end
