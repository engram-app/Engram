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
  """
  def merged_changes_page(user, vault, after_seq, after_id, limit, fields)
      when is_integer(after_seq) and is_integer(limit) do
    {:ok, %{changes: notes, has_more: notes_more}} =
      Notes.list_changes_by_seq(user, vault, after_seq,
        after_id: after_id,
        limit: limit + 1,
        fields: fields
      )

    # Attachments carry no note content, so the `fields` projection is n/a here.
    {:ok, %{changes: atts, has_more: atts_more}} =
      Attachments.list_changes_by_seq(user, vault, after_seq,
        after_id: after_id,
        limit: limit + 1
      )

    merged =
      (Enum.map(notes, &Map.put(&1, :type, :note)) ++
         Enum.map(atts, &Map.put(&1, :type, :attachment)))
      |> Enum.sort_by(&{&1.seq, &1.id})

    {page, has_more} =
      if length(merged) > limit do
        {Enum.take(merged, limit), true}
      else
        {merged, notes_more or atts_more}
      end

    next =
      if has_more do
        last = List.last(page)
        {last.seq, last.id}
      end

    %{page: page, has_more: has_more, next: next}
  end
end
