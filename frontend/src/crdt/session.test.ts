import { describe, it, expect, vi, beforeEach } from 'vitest'
import {
  startCrdtSession,
  openDoc,
  enroll,
  handleFrame,
  stopCrdtSession,
  resyncOpenDocs,
  docPathFromDocId,
} from './session'

const VAULT = 'vault-xyz'

describe('crdt session', () => {
  beforeEach(() => stopCrdtSession())

  it('openDoc returns a Y.Text + awareness for a .md path', async () => {
    startCrdtSession({ vaultId: VAULT, push: () => {} })
    const handle = await openDoc('note.md')
    expect(handle).not.toBeNull()
    handle!.ytext.insert(0, 'hi')
    expect(handle!.ytext.toJSON()).toBe('hi')
  })

  it('openDoc returns null for non-.md', async () => {
    startCrdtSession({ vaultId: VAULT, push: () => {} })
    expect(await openDoc('x.canvas')).toBeNull()
  })

  it('enroll pushes a STEP1 frame addressed by docId', async () => {
    const push = vi.fn()
    startCrdtSession({ vaultId: VAULT, push })
    await openDoc('note.md')
    enroll('note.md')
    await vi.waitFor(() => expect(push).toHaveBeenCalled())
    expect(push.mock.calls[0]![0]).toBe(`${VAULT}/note.md`)
  })

  it('a local edit pushes an update frame via the transport', async () => {
    const push = vi.fn()
    startCrdtSession({ vaultId: VAULT, push })
    const handle = await openDoc('note.md')
    handle!.ytext.insert(0, 'abc')
    await vi.waitFor(() => expect(push).toHaveBeenCalled())
    expect(push.mock.calls[push.mock.calls.length - 1]![0]).toBe(`${VAULT}/note.md`)
  })

  it('docPathFromDocId strips the vault prefix', () => {
    startCrdtSession({ vaultId: VAULT, push: () => {} })
    expect(docPathFromDocId(`${VAULT}/a/b.md`)).toBe('a/b.md')
  })

  it('resyncOpenDocs re-sends STEP1 for open docs on reconnect', async () => {
    const push = vi.fn()
    startCrdtSession({ vaultId: VAULT, push })
    await openDoc('note.md')
    enroll('note.md')
    await vi.waitFor(() => expect(push).toHaveBeenCalled())
    push.mockClear()
    resyncOpenDocs()
    await vi.waitFor(() => expect(push).toHaveBeenCalled())
    expect(push.mock.calls[0]![0]).toBe(`${VAULT}/note.md`)
  })

  it('handleFrame drops frames for docs not open in the session', async () => {
    // Build a valid STEP2/UPDATE frame from a separate session
    const frames: Array<[string, string]> = []
    startCrdtSession({ vaultId: VAULT, push: (id, b64) => frames.push([id, b64]) })
    const a = await openDoc('note.md')
    a!.ytext.insert(0, 'ghost-content')
    await vi.waitFor(() => expect(frames.length).toBeGreaterThan(0))
    const [, b64] = frames[frames.length - 1]!
    stopCrdtSession()

    // New session — do NOT open ghost.md
    startCrdtSession({ vaultId: VAULT, push: () => {} })
    await handleFrame('ghost.md', b64)

    // Now open ghost.md; it must not contain the leaked content
    const ghostHandle = await openDoc('ghost.md')
    expect(ghostHandle!.ytext.toJSON()).not.toContain('ghost-content')
  })

  it('handleFrame applies inbound bytes (two-session round-trip)', async () => {
    // Session A emits frames into a buffer; feed them into session B.
    const frames: Array<[string, string]> = []
    startCrdtSession({ vaultId: VAULT, push: (id, b64) => frames.push([id, b64]) })
    const a = await openDoc('note.md')
    a!.ytext.insert(0, 'payload')
    await vi.waitFor(() => expect(frames.length).toBeGreaterThan(0))
    const [, b64] = frames[frames.length - 1]!
    stopCrdtSession()
    startCrdtSession({ vaultId: VAULT, push: () => {} })
    await openDoc('note.md')
    await handleFrame('note.md', b64)
    const b = await openDoc('note.md')
    expect(b!.ytext.toJSON()).toContain('payload')
  })
})
