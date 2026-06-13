import { Socket, Channel } from 'phoenix'
import type { QueryClient } from '@tanstack/react-query'
import { getWsBase, joinWsUrl } from './base'

let socket: Socket | null = null
let channel: Channel | null = null

interface ConnectOptions {
  userId: string
  vaultId: string
  getToken: () => Promise<string | null>
  queryClient: QueryClient
}

export interface NoteChangedPayload {
  event_type: string
  path: string
  vault_id: string
  // Present since backend change_json adds note id. Always invalidate by id
  // when available — useNote keys by id since the URL-by-id refactor.
  id?: string
  content?: string
  title?: string
  folder?: string
  tags?: string[]
  mtime?: number
  updated_at?: string
  version?: number
}

type NoteChangedListener = (payload: NoteChangedPayload) => void
const listeners = new Set<NoteChangedListener>()

export function subscribeToNoteChanges(listener: NoteChangedListener): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

// ── Coalesced list invalidation ───────────────────────────────────────────
// A plugin sync burst delivers one note_changed per note (hundreds in a
// row). Invalidating every folder/search list per event refetched
// O(events × active queries) against a backend that decrypts rows
// server-side — the per-note keys stay synchronous (cheap, exact), but
// list-level keys batch into one targeted flush per window.

const BATCH_WINDOW_MS = 250

interface PendingBatch {
  queryClient: QueryClient
  vaultId: string
  folders: Set<string>
  timer: ReturnType<typeof setTimeout>
}

let pending: PendingBatch | null = null

function folderFromPath(path: string): string {
  const idx = path.lastIndexOf('/')
  return idx === -1 ? '' : path.slice(0, idx)
}

interface CachedFolders {
  folders?: Array<{ id: string; name: string }>
}

function flushBatch(batch: PendingBatch): void {
  const { queryClient, vaultId, folders } = batch
  queryClient.invalidateQueries({ queryKey: ['folders', vaultId] })
  queryClient.invalidateQueries({ queryKey: ['search', vaultId] })

  // The by-id keys are keyed on folder-marker ids; resolve names through
  // the cached tree. Unknown folders (just created, tree not refetched
  // yet) fall back to one broad invalidation.
  const cached = queryClient.getQueryData<CachedFolders>(['folders', vaultId])
  let broadById = false

  for (const folder of folders) {
    queryClient.invalidateQueries({ queryKey: ['folderNotes', vaultId, folder] })
    const entry = cached?.folders?.find((f) => f.name === folder)
    if (entry) {
      queryClient.invalidateQueries({ queryKey: ['folder-notes-by-id', vaultId, entry.id] })
    } else {
      broadById = true
    }
  }

  if (broadById) {
    queryClient.invalidateQueries({ queryKey: ['folder-notes-by-id', vaultId] })
  }
}

/** Test hook: drop any pending batch without flushing. */
export function __resetNoteChangeBatch(): void {
  if (pending) {
    clearTimeout(pending.timer)
    pending = null
  }
}

export function handleNoteChanged(
  payload: NoteChangedPayload,
  queryClient: QueryClient,
  activeVaultId: string,
): void {
  // Server broadcasts on the vault topic; this guard protects against
  // an unrelated vault's payload reaching the wrong queryClient (e.g.
  // mid-vault-switch race).
  if (payload.vault_id !== activeVaultId) return

  if (payload.id != null) {
    queryClient.invalidateQueries({ queryKey: ['note', activeVaultId, payload.id] })
  }
  // Legacy path-keyed key still in use by some hooks; keep invalidating it.
  queryClient.invalidateQueries({ queryKey: ['note', activeVaultId, payload.path] })

  if (!pending) {
    const batch: PendingBatch = {
      queryClient,
      vaultId: activeVaultId,
      folders: new Set(),
      timer: setTimeout(() => {
        pending = null
        flushBatch(batch)
      }, BATCH_WINDOW_MS),
    }
    pending = batch
  }

  pending.folders.add(payload.folder ?? folderFromPath(payload.path))

  for (const listener of listeners) listener(payload)
}

// Bulk pushes (POST /api/notes/batch) broadcast ONE notes.batch digest
// (op "upsert", metadata-only entries) instead of N note_changed events.
// Re-feed each entry through handleNoteChanged so per-note keys invalidate
// synchronously and list keys ride the same coalescing window.
export interface NotesBatchPayload {
  op: string
  vault_id?: string
  notes?: Array<{
    id: string
    path: string
    folder?: string
    title?: string
    tags?: string[]
    mtime?: number
    version?: number
    updated_at?: string
    content_hash?: string
  }>
}

export function handleNotesBatch(
  payload: NotesBatchPayload,
  queryClient: QueryClient,
  activeVaultId: string,
): void {
  if (payload.op !== 'upsert') return
  if (payload.vault_id !== activeVaultId) return

  for (const note of payload.notes ?? []) {
    handleNoteChanged(
      { event_type: 'upsert', vault_id: activeVaultId, ...note },
      queryClient,
      activeVaultId,
    )
  }
}

export async function connectChannel({ userId, vaultId, getToken, queryClient }: ConnectOptions) {
  disconnectChannel()

  const token = await getToken()

  socket = new Socket(joinWsUrl(getWsBase(), '/socket'), {
    params: { token: token ?? '' },
  })

  socket.connect()

  const topic = `sync:${userId}:${vaultId}`
  channel = socket.channel(topic)

  channel.on('note_changed', (payload: NoteChangedPayload) => {
    handleNoteChanged(payload, queryClient, vaultId)
  })

  channel.on('notes.batch', (payload: NotesBatchPayload) => {
    handleNotesBatch(payload, queryClient, vaultId)
  })

  channel
    .join()
    .receive('ok', () => console.log(`Joined ${topic}`))
    .receive('error', (resp) => console.error('Channel join failed', resp))
}

export function disconnectChannel() {
  __resetNoteChangeBatch()
  if (channel) {
    channel.leave()
    channel = null
  }
  if (socket) {
    socket.disconnect()
    socket = null
  }
}
