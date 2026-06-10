import { Socket, Channel } from 'phoenix'
import type { QueryClient } from '@tanstack/react-query'

let socket: Socket | null = null
let channel: Channel | null = null

interface ConnectOptions {
  userId: number
  vaultId: number
  getToken: () => Promise<string | null>
  queryClient: QueryClient
}

export interface NoteChangedPayload {
  event_type: string
  path: string
  vault_id: number
  // Present since backend change_json adds note id. Always invalidate by id
  // when available — useNote keys by id since the URL-by-id refactor.
  id?: number
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

export function handleNoteChanged(
  payload: NoteChangedPayload,
  queryClient: QueryClient,
  activeVaultId: number,
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
  queryClient.invalidateQueries({ queryKey: ['folders', activeVaultId] })
  queryClient.invalidateQueries({ queryKey: ['folderNotes', activeVaultId] })
  queryClient.invalidateQueries({ queryKey: ['folder-notes-by-id', activeVaultId] })
  queryClient.invalidateQueries({ queryKey: ['search', activeVaultId] })

  for (const listener of listeners) listener(payload)
}

export async function connectChannel({ userId, vaultId, getToken, queryClient }: ConnectOptions) {
  disconnectChannel()

  const token = await getToken()

  socket = new Socket('/socket', {
    params: { token: token ?? '' },
  })

  socket.connect()

  const topic = `sync:${userId}:${vaultId}`
  channel = socket.channel(topic)

  channel.on('note_changed', (payload: NoteChangedPayload) => {
    handleNoteChanged(payload, queryClient, vaultId)
  })

  channel
    .join()
    .receive('ok', () => console.log(`Joined ${topic}`))
    .receive('error', (resp) => console.error('Channel join failed', resp))
}

export function disconnectChannel() {
  if (channel) {
    channel.leave()
    channel = null
  }
  if (socket) {
    socket.disconnect()
    socket = null
  }
}
