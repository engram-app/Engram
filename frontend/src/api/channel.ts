import { Socket, Channel } from 'phoenix'
import type { QueryClient } from '@tanstack/react-query'
import { getWsBase, joinWsUrl } from './base'
import { ROOT_FOLDER_ID } from './queries'
import {
  startCrdtSession,
  stopCrdtSession,
  handleFrame as crdtHandleFrame,
  enroll as crdtEnroll,
  resyncOpenDocs,
  docPathFromDocId,
  notifyCrdtChannelJoined,
  notifyCrdtChannelError,
} from '../crdt/session'

export const RECONNECT_JITTER_DEFAULT_MS = 5000
export const RECONNECT_JITTER_MAX_MS = 60_000

// phoenix.js's own default reconnect steps — kept for the 2nd+ attempt. Only
// the FIRST reconnect is full-jittered, to de-sync a drained fleet so the
// freshly-booted node isn't stampeded.
const PHX_RECONNECT_STEPS = [10, 50, 100, 150, 200, 250, 500, 1000, 2000]

let serverJitterMs: number | null = null

export function clampReconnectJitter(raw: unknown): number | null {
  if (typeof raw !== 'number' || !Number.isFinite(raw) || raw <= 0) return null
  return Math.min(raw, RECONNECT_JITTER_MAX_MS)
}

export function computeReconnectMs(
  tries: number,
  jitterMaxMs: number | null,
  rng: () => number = Math.random,
): number {
  if (tries <= 1) return rng() * (jitterMaxMs ?? RECONNECT_JITTER_DEFAULT_MS)
  return PHX_RECONNECT_STEPS[tries - 1] ?? 5000
}

/** Cache the server-advertised jitter window from the sync join reply.
 *  Clamped + validated so a malformed/hostile payload can't make the client
 *  hang or hammer. Non-positive windows (including 0) are rejected, forcing
 *  the client to fall back to the default floor rather than disabling jitter. */
export function captureServerJitter(resp: unknown): void {
  const raw = (resp as { reconnect_jitter_max_ms?: unknown })?.reconnect_jitter_max_ms
  const clamped = clampReconnectJitter(raw)
  if (clamped !== null) serverJitterMs = clamped
}

/** Test seams. */
export function __getServerJitterMs(): number | null {
  return serverJitterMs
}
export function __resetServerJitterMs(): void {
  serverJitterMs = null
}

let socket: Socket | null = null
let channel: Channel | null = null
let crdtChannel: Channel | null = null

interface ConnectOptions {
  userId: string
  vaultId: string
  getToken: () => Promise<string | null>
  queryClient: QueryClient
  onSocketOpen?: () => void
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
    // Root has no folder marker; its id-keyed list keys under the sentinel.
    if (folder === '') {
      queryClient.invalidateQueries({ queryKey: ['folder-notes-by-id', vaultId, ROOT_FOLDER_ID] })
      continue
    }
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

export async function connectChannel({ userId, vaultId, getToken, queryClient, onSocketOpen }: ConnectOptions) {
  disconnectChannel()

  const token = await getToken()

  socket = new Socket(joinWsUrl(getWsBase(), '/socket'), {
    params: { token: token ?? '' },
    reconnectAfterMs: (tries: number) => computeReconnectMs(tries, serverJitterMs),
  })

  socket.connect()

  // Fires on initial connect AND every reconnect — the durable-feed catch-up
  // trigger. The socket can drop events while disconnected (no replay), so a
  // reconnect kicks a cursor pull to backfill the gap.
  // Also re-arms CRDT handshakes on reconnect so the session re-syncs state.
  socket.onOpen(() => {
    resyncOpenDocs()
    onSocketOpen?.()
  })

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
    .receive('ok', (resp) => {
      captureServerJitter(resp)
      console.log(`Joined ${topic}`)
    })
    .receive('error', (resp) => console.error('Channel join failed', resp))

  // CRDT note-sync channel — rides the same Clerk-authed socket. The session
  // singleton owns the Y.Doc registry; this channel is just its transport.
  startCrdtSession({
    vaultId,
    push: (docId, b64) => {
      crdtChannel?.push('crdt_msg', { doc_id: docId, b64 })
    },
  })
  const crdtTopic = `crdt:${userId}:${vaultId}`
  crdtChannel = socket.channel(crdtTopic, { crdt_proto: 2 })
  crdtChannel.on('crdt_msg', (p: { doc_id: string; b64: string }) => {
    void crdtHandleFrame(docPathFromDocId(p.doc_id), p.b64).catch((err) =>
      console.warn('CRDT frame handling error (dropped)', err),
    )
  })
  crdtChannel.on('crdt_doc_ready', (p: { doc_id: string }) => {
    crdtEnroll(docPathFromDocId(p.doc_id))
  })
  crdtChannel
    .join()
    .receive('ok', () => {
      notifyCrdtChannelJoined()
      console.log(`Joined ${crdtTopic}`)
    })
    .receive('error', (resp) => {
      notifyCrdtChannelError()
      console.error('CRDT channel join failed', resp)
    })
}

export function disconnectChannel() {
  __resetNoteChangeBatch()
  if (crdtChannel) {
    crdtChannel.leave()
    crdtChannel = null
  }
  stopCrdtSession()
  if (channel) {
    channel.leave()
    channel = null
  }
  if (socket) {
    socket.disconnect()
    socket = null
  }
}
