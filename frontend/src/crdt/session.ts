import { Awareness } from 'y-protocols/awareness'
import type * as Y from 'yjs'
import { CrdtChannel } from './channel'
import { CrdtEnrollment } from './enrollment'
import { CrdtManager } from './manager'

interface Session {
  vaultId: string
  manager: CrdtManager
  channel: CrdtChannel
  enrollment: CrdtEnrollment
  awareness: Map<string, Awareness>
}

let session: Session | null = null

export interface StartSessionOpts {
  vaultId: string
  /** Transport out: push a base64 y-protocols frame for docId to the server. */
  push: (docId: string, b64: string) => void
  onPersistError?: (path: string, err: unknown) => void
}

export function startCrdtSession(opts: StartSessionOpts): void {
  stopCrdtSession()
  // Declare channel first so the onUpdate closure can reference it.
  // channel is assigned before any update tick fires.
  let channel: CrdtChannel
  const manager = new CrdtManager({
    dbPrefix: opts.vaultId,
    onUpdate: (docId, update) => channel.sendUpdateRaw(docId, update),
    onPersistError: opts.onPersistError,
  })
  channel = new CrdtChannel({ manager, send: opts.push })
  const enrollment = new CrdtEnrollment({
    startSync: (p) => channel.startSync(p),
    resetSync: (p) => channel.resetSync(p),
    onAfterEnroll: (p) => manager.flattenIfBloated(p).then(() => undefined),
  })
  session = { vaultId: opts.vaultId, manager, channel, enrollment, awareness: new Map() }
}

export function stopCrdtSession(): void {
  if (!session) return
  for (const a of session.awareness.values()) a.destroy()
  void session.manager.destroy().catch((e) => console.warn('CRDT session teardown error', e))
  session = null
}

export async function openDoc(
  path: string,
): Promise<{ ytext: Y.Text; awareness: Awareness } | null> {
  if (!session || !path.endsWith('.md')) return null
  const ytext = await session.manager.getSharedText(path)
  let awareness = session.awareness.get(path)
  if (!awareness) {
    awareness = new Awareness(ytext.doc!)
    session.awareness.set(path, awareness)
  }
  return { ytext, awareness }
}

export function closeDoc(path: string): void {
  if (!session) return
  const a = session.awareness.get(path)
  if (a) {
    a.destroy()
    session.awareness.delete(path)
  }
  session.manager.closeDoc(path)
}

export function enroll(path: string): void {
  session?.enrollment.enroll(path)
}

export async function handleFrame(path: string, b64: string): Promise<void> {
  if (!session) return
  if (!session.manager.hasDoc(path)) return // not active — drop; STEP1 re-syncs on reopen
  await session.channel.handleFrame(path, b64)
}

/** On socket reconnect: clear each open doc's handshake guard and re-enroll it
 *  so a fresh STEP1 is sent. Removes the dependency on the server re-firing
 *  crdt_doc_ready. Open docs are those with a live Awareness entry (created by
 *  openDoc, removed by closeDoc). */
export function resyncOpenDocs(): void {
  if (!session) return
  for (const path of session.awareness.keys()) {
    session.enrollment.reset(path)   // clears enrolled set + CrdtChannel.initiated guard
    session.enrollment.enroll(path)  // re-sends STEP1 (idempotent; reset re-armed it)
  }
}

export function resetAll(): void {
  session?.enrollment.resetAll()
}

export function docPathFromDocId(docId: string): string {
  const idx = docId.indexOf('/')
  return idx === -1 ? docId : docId.slice(idx + 1)
}
