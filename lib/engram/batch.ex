defmodule Engram.Batch do
  @moduledoc """
  The one place chunk and page sizes for bulk work live (#2169).

  Every bulk site (cascades, sweeps, fan-outs) asks here instead of carrying
  its own number, so two callers of the same kind of work cannot drift apart.
  The values are the measured or incident-tested ones; change one only with a
  new measurement, and update the reason next to it.

  Not here, deliberately: `Engram.Jobs`' 50-id probe size is a planner limit
  (index probe vs scan on `oban_jobs`), not a batch size.
  """

  # Bound parameters per statement: Postgres allows 65_535. Oban's Basic
  # engine binds up to 17 per job (4_095 jobs max) and a folder-marker row
  # binds 14 (4_681 rows max), so 2_000 leaves each a wide margin and a new
  # column cannot re-arm the overflow.
  @insert_rows 2_000

  # Note ids per ReleaseIndexEntries link. Fixed cost per link is the whole
  # index (snapshot decrypt/re-encrypt or room edit + tail append, ~0.2-0.5 s
  # at 20-40k entries) while each extra id adds ~0.05 ms: 20k ids took 20 s at
  # 500 per job and 5.7 s at 2_000, slowest job ~0.8 s at both. Above 2_000 the
  # slowest job and the delete set broadcast to every client keep growing for
  # a shrinking total-time win. Not a bind-param limit.
  @release_index_entries 2_000

  # Notes the embed reconcile sweep stamps and enqueues per statement. Each
  # page drops out of the next page's query (the stamp), so a loop of pages
  # walks the whole backlog.
  @reconcile_page 1_000

  # Rows per transaction in a folder delete cascade (#2159), for the
  # attachment and notes legs, and the request-size cap of batch_delete/3.
  # Small enough that one chunk's transaction stays far inside the 15 s
  # statement timeout that the 7,440-attachment delete (2026-10-24) hit.
  @folder_delete 500

  # Rows per page of a client-facing list (`Engram.Pager`). Metadata only, so
  # a page is a few hundred KB at most; the cap bounds decrypt CPU and memory
  # per request. MCP pages default smaller (200) because the whole page lands
  # in an LLM context; REST pages default to 500 so an older client that never
  # sends `limit` is truncated as rarely as possible (it is told, via
  # `truncated`). A 7.4k-note folder (the largest in prod, 2026-10) is 15 REST
  # default pages.
  @page_default 200
  @rest_page_default 500
  @page_max 1_000

  # Pending checkpoint ids `GET /sync/quiescence` reads per call. It needs
  # "is anything owed", not the full backlog (10k+ during a storm), and the
  # live-room split only matters for the ids it can see.
  @quiescence_cap 1_000

  @doc "Rows or jobs per bulk `insert_all` statement (bind-parameter bound)."
  @spec insert_rows() :: 2_000
  def insert_rows, do: @insert_rows

  @doc "Max note ids per `ReleaseIndexEntries` link, i.e. per index-room change."
  @spec release_index_entries() :: 2_000
  def release_index_entries, do: @release_index_entries

  @doc "Notes per page of the embed reconcile sweep."
  @spec reconcile_page() :: 1_000
  def reconcile_page, do: @reconcile_page

  @doc "Rows per folder-delete transaction and per `batch_delete/3` call."
  @spec folder_delete() :: 500
  def folder_delete, do: @folder_delete

  @doc """
  Most ids or paths one client batch request (notes and attachments
  batch-delete and batch-move) may name; above it the request is refused
  (`{:error, :batch_too_large}`, 422). One folder-delete chunk on purpose: a
  capped request is at most one chunk's transaction under the vault lock.
  """
  @spec batch_request_max() :: 500
  def batch_request_max, do: @folder_delete

  @doc "Default rows per page of a paged MCP list when the client sends no limit."
  @spec page_default() :: 200
  def page_default, do: @page_default

  @doc "Default rows per page of a paged REST list when the client sends no limit."
  @spec rest_page_default() :: 500
  def rest_page_default, do: @rest_page_default

  @doc "Hard ceiling on rows per page of a paged list; a larger `limit` is clamped."
  @spec page_max() :: 1_000
  def page_max, do: @page_max

  @doc "Max pending checkpoint ids read by one quiescence probe."
  @spec quiescence_cap() :: 1_000
  def quiescence_cap, do: @quiescence_cap
end
