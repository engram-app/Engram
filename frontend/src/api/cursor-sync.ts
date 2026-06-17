import type { QueryClient } from '@tanstack/react-query'
import { api, ApiError } from './client'
import { handleNoteChanged, type NoteChangedPayload } from './channel'
import { encodeCursor, getCursor, setCursor, MAX_UUID } from './cursor'

interface ChangeRow {
  type: 'note' | 'attachment'
  id: string
  path: string
  folder?: string
  deleted?: boolean
  seq: number
}

interface ChangesPage {
  changes: ChangeRow[]
  next_cursor: string | null
  has_more: boolean
}

interface ManifestHead {
  change_seq: number
}

// Backstop against a server bug returning has_more:true forever.
const MAX_PAGES = 10_000

// Single-flight: reconnect + focus can fire together; one run per vault.
const inflight = new Map<string, Promise<void>>()

/**
 * Reconcile this device against the ordered change feed. On a fresh device
 * (no stored cursor) it seeds the cursor at the manifest head and applies
 * nothing (current state is already on screen via the normal queries). With a
 * cursor it pulls metadata-only deltas and feeds each note row through the
 * socket's invalidation pipeline. Single-flight per vault.
 */
export function runCursorSync(vaultId: string, queryClient: QueryClient): Promise<void> {
  const existing = inflight.get(vaultId)
  if (existing) return existing
  const run = doCursorSync(vaultId, queryClient).finally(() => inflight.delete(vaultId))
  inflight.set(vaultId, run)
  return run
}

async function doCursorSync(vaultId: string, queryClient: QueryClient): Promise<void> {
  const cursor = getCursor(vaultId)
  if (cursor == null) {
    setCursor(vaultId, await bootstrap())
    return
  }
  try {
    await pullLoop(vaultId, cursor, queryClient)
  } catch (e) {
    // Stale/tampered cursor (400) or compacted history (410, dormant until
    // PR D) → re-establish a head cursor. Bootstrap re-renders nothing; the
    // normal queries already hold current state.
    if (e instanceof ApiError && (e.status === 400 || e.status === 410)) {
      setCursor(vaultId, await bootstrap())
      return
    }
    throw e
  }
}

async function bootstrap(): Promise<string> {
  const head = await api.get<ManifestHead>('/sync/manifest')
  return encodeCursor(head.change_seq, MAX_UUID)
}

async function pullLoop(
  vaultId: string,
  startCursor: string,
  queryClient: QueryClient,
): Promise<void> {
  let cursor = startCursor
  for (let i = 0; i < MAX_PAGES; i++) {
    // cursor is already url-safe base64 (encodeCursor), so encodeURIComponent
    // is a no-op here — kept defensively in case the token shape ever changes.
    const page = await api.get<ChangesPage>(
      `/sync/changes?cursor=${encodeURIComponent(cursor)}&fields=meta`,
    )
    for (const row of page.changes) applyRow(row, queryClient, vaultId)

    const next = nextCursor(page, cursor)
    if (next !== cursor) {
      cursor = next
      setCursor(vaultId, cursor)
    }
    if (!page.has_more) break
    if (i === MAX_PAGES - 1) {
      // Don't silently truncate: a feed still reporting has_more at the cap is
      // a server bug (or an absurdly large gap). The cursor is persisted, so
      // the next trigger resumes — but surface it rather than hide the stall.
      console.warn(
        `[cursor-sync] vault ${vaultId}: hit MAX_PAGES (${MAX_PAGES}) with has_more still true; pull will resume on the next trigger`,
      )
    }
  }
}

// The backend guarantees next_cursor is non-null ONLY when has_more is true
// (sync_controller renders next_cursor inside `if has_more`), so the first
// branch never fires on a final page. On the final page we encode the head
// ourselves from the last applied row; an empty page keeps the prior cursor.
function nextCursor(page: ChangesPage, prev: string): string {
  if (page.next_cursor) return page.next_cursor
  const last = page.changes[page.changes.length - 1]
  return last ? encodeCursor(last.seq, last.id) : prev
}

// The web has no local mirror, so a change row is a *signal*: note rows reuse
// the socket's invalidation pipeline; attachment rows get no UI action (parity
// with the socket, which carries no attachment event) but the cursor advances.
function applyRow(row: ChangeRow, queryClient: QueryClient, vaultId: string): void {
  if (row.type !== 'note') return
  const payload: NoteChangedPayload = {
    event_type: row.deleted ? 'delete' : 'upsert',
    vault_id: vaultId,
    id: row.id,
    path: row.path,
    folder: row.folder,
  }
  handleNoteChanged(payload, queryClient, vaultId)
}

/**
 * Install the cursor-sync triggers: run once now, then on every window focus.
 * (Socket reconnect is wired separately via connectChannel's onSocketOpen.)
 * Returns a cleanup that removes the focus listener. `run` is injectable for
 * tests; production uses the default runCursorSync.
 */
export function installCursorSyncTriggers(
  vaultId: string,
  queryClient: QueryClient,
  run: (vaultId: string, queryClient: QueryClient) => void = runCursorSync,
): () => void {
  run(vaultId, queryClient)
  const onFocus = () => run(vaultId, queryClient)
  window.addEventListener('focus', onFocus)
  return () => window.removeEventListener('focus', onFocus)
}

/** Test hook: drop any in-flight single-flight entries. */
export function __resetCursorSyncInflight(): void {
  inflight.clear()
}
