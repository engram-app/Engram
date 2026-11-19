defmodule Engram.Sync do
  @moduledoc """
  Ordered change-log sync: builds one seq-ordered page merging the notes and
  attachments change feeds for a vault (the socket op-log catch-up feed).
  """
  alias Engram.{Attachments, Notes}
  alias Engram.Folders.WriteStop

  @doc """
  The highest seq this feed can serve for `vault`. Lower than the vault's
  `change_seq` whenever the vault's last bump was a folder write (folder rows
  are not in the feed), so a client cursor that reached it has seen every row
  the feed holds. Run inside `Repo.with_tenant/2`.
  """
  @spec feed_head(map(), map(), keyword()) :: non_neg_integer()
  def feed_head(user, vault, opts \\ []) do
    own = max(Notes.feed_head_seq(user, vault), Attachments.feed_head_seq(user, vault))

    # The moved-folder feed serves rows at its folders' seqs, but only to the
    # clients that get it (`moved: moved_feed?/1`, on by default): the S4
    # plugin pulls none, so its cursor could never reach a head counting them.
    if Keyword.get(opts, :moved, true),
      do:
        Enum.max([
          own,
          Notes.moved_head(user, vault.id, own),
          Attachments.moved_head(user, vault.id, own)
        ]),
      else: own
  end

  # compat(plugin): moved_folder_feed - remove when plugin floor reaches WriteStop.s4_plugin/0 (#2523)
  @doc """
  Whether a client announcing `plugin_version` gets the moved-folder feed
  (`Notes.list_moved_changes/4`): every client below
  `Engram.Folders.WriteStop.s4_plugin/0`, a sentinel no released plugin
  reaches (1.40.0 shipped without working moved-folder handling), so today
  every client. A missing or unreadable version gets it: the old view is the
  safe one. `feed_head/3` and `merged_changes_page/8` take the same answer as
  `moved:`, so a cursor head always matches what is served.
  """
  @spec moved_feed?(String.t() | nil) :: boolean()
  def moved_feed?(plugin_version) do
    with v when is_binary(v) <- plugin_version,
         {:ok, v} <- Version.parse(v) do
      Version.compare(v, Version.parse!(WriteStop.s4_plugin())) == :lt
    else
      _ -> true
    end
  end

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

  `opts`: `moved:` (default true) merges in the moved-folder feed
  (`Notes.list_moved_changes/4`, see `moved_feed?/1`).
  """
  def merged_changes_page(
        user,
        vault,
        after_seq,
        after_id,
        limit,
        fields,
        max_bytes \\ nil,
        opts \\ []
      )
      when is_integer(after_seq) and is_integer(limit) do
    # One slot per in-flight page (see PageGate): the byte budget bounds ONE
    # page, this bounds how many exist at once so a burst of first syncs queues
    # instead of stacking memory. Queues, never rejects — the client aborts its
    # whole walk on a rejected fetch.
    Engram.Sync.PageGate.with_slot(fn ->
      build_page(user, vault, after_seq, after_id, limit, fields, max_bytes, opts)
    end)
  end

  defp build_page(user, vault, after_seq, after_id, limit, fields, max_bytes, opts) do
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

    # The moved-folder feed (`moved_feed?/1`), a third feed under the same
    # watermark. `moved: false` (the S4 plugin) reads nothing.
    #
    # Read after the other two, so its share of the page is known before any
    # of its bodies is read (`room/6`): one row and byte budget per page.
    {:ok, %{changes: moved, has_more: moved_more}} =
      if Keyword.get(opts, :moved, true),
        do:
          Notes.list_moved_changes(user, vault, after_seq,
            after_id: after_id,
            limit: limit + 1,
            fields: fields,
            max_bytes: max_bytes,
            room: &room({notes, notes_more}, {atts, atts_more}, &1, limit, fields, max_bytes)
          ),
        else: {:ok, %{changes: [], has_more: false}}

    # Its attachment twin (S6 step 6): metadata only, no budget.
    {:ok, %{changes: att_moved, has_more: att_moved_more}} =
      if Keyword.get(opts, :moved, true),
        do:
          Attachments.list_moved_changes(user, vault, after_seq, after_id: after_id, limit: limit),
        else: {:ok, %{changes: [], has_more: false}}

    # Stable: a moved attachment's delete stays before its upsert (same key).
    merged =
      (Enum.map(notes ++ moved, &Map.put(&1, :type, :note)) ++
         Enum.map(atts ++ att_moved, &Map.put(&1, :type, :attachment)))
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
      [
        notes_more && List.last(notes),
        atts_more && List.last(atts),
        moved_more && List.last(moved),
        att_moved_more && List.last(att_moved)
      ]
      |> Enum.filter(&is_map/1)
      |> Enum.map(&key/1)
      |> Enum.min(fn -> nil end)

    capped = if watermark, do: Enum.filter(merged, &(key(&1) <= watermark)), else: merged

    {page, has_more} =
      if length(capped) > limit do
        {take_pairs(capped, limit), true}
      else
        # `capped` shorter than `merged` means the watermark held rows back, so
        # there is definitionally more to serve even if neither feed said so.
        {capped,
         notes_more or atts_more or moved_more or att_moved_more or
           length(capped) < length(merged)}
      end

    # One byte budget for the page: the notes feed and the moved-folder feed
    # each cut at it, so together they could carry twice.
    {page, has_more} =
      if moved == [],
        do: {page, has_more},
        else: Notes.trim_to_budget(page, has_more, fields, max_bytes || Notes.page_max_bytes())

    # A byte cut can fall between a moved attachment's halves: serve the
    # pair on the next page instead.
    {page, has_more} =
      case List.last(page) do
        %{pair: true} when length(page) > 1 -> {Enum.drop(page, -1), true}
        _ -> {page, has_more}
      end

    next =
      if has_more and page != [] do
        last = List.last(page)
        {last.seq, last.id}
      end

    # The pair marker is this module's own (`take_pairs/2`), not the wire's.
    %{page: Enum.map(page, &Map.delete(&1, :pair)), has_more: has_more, next: next}
  end

  # What is left of the page for a moved folder at `seq`: `:skip` when a
  # feed that has more stops below `seq` (the watermark would drop every row
  # at it) or the rows below `seq` already fill the page; else the rows and
  # bytes those rows leave.
  defp room({notes, notes_more}, {atts, atts_more}, seq, limit, fields, max_bytes) do
    stops_below? =
      (notes_more and notes != [] and List.last(notes).seq < seq) or
        (atts_more and atts != [] and List.last(atts).seq < seq)

    below = Enum.filter(notes ++ atts, &(&1.seq < seq))
    rows = limit - length(below)

    cond do
      stops_below? or rows <= 0 ->
        :skip

      fields == :all ->
        budget = max_bytes || Notes.page_max_bytes()
        {rows, budget - Enum.sum(Enum.map(below, &byte_size(&1[:content] || "")))}

      true ->
        {rows, max_bytes}
    end
  end

  defp key(row), do: {row.seq, row.id}

  # The first `limit` rows, plus the upsert half of a moved attachment whose
  # delete half is the last one (`Attachments.list_moved_changes/4`): both
  # share one `(seq, id)` key, so a cursor between them would skip the
  # upsert. At most `limit + 1` rows.
  defp take_pairs(rows, limit) do
    {page, rest} = Enum.split(rows, limit)

    case {List.last(page), rest} do
      {%{pair: true} = del, [%{id: id, seq: seq} = up | _]}
      when id == del.id and seq == del.seq ->
        page ++ [up]

      _ ->
        page
    end
  end
end
