import { describe, it, expect, vi } from 'vitest'
import { CrdtManager } from './manager'
import { CrdtChannel } from './channel'

function mkManager() {
  return new CrdtManager({
    dbPrefix: `v-${Math.random().toString(36).slice(2)}`,
    onUpdate: () => {},
  })
}

describe('CrdtChannel', () => {
  it('startSync sends STEP1 at most once per doc', async () => {
    const send = vi.fn()
    const ch = new CrdtChannel({ manager: mkManager(), send })
    await ch.startSync('n.md')
    await ch.startSync('n.md')
    expect(send).toHaveBeenCalledTimes(1)
    expect(send.mock.calls[0]![0]).toContain('/n.md') // docId
    expect(typeof send.mock.calls[0]![1]).toBe('string') // base64 frame
  })

  it('resetSync re-arms the handshake', async () => {
    const send = vi.fn()
    const ch = new CrdtChannel({ manager: mkManager(), send })
    await ch.startSync('n.md')
    ch.resetSync('n.md')
    await ch.startSync('n.md')
    expect(send).toHaveBeenCalledTimes(2)
  })

  it('applies an inbound update frame to the doc (round-trip via two peers)', async () => {
    // Peer A produces an update frame; peer B ingests it via handleFrame.
    const aMgr = mkManager()
    const aSends: Array<[string, string]> = []
    const aCh = new CrdtChannel({ manager: aMgr, send: (id, f) => aSends.push([id, f]) })
    const aText = await aMgr.getSharedText('n.md')
    // Hook A's local update through sendUpdateRaw the way session.ts will.
    aText.insert(0, 'merged-content')
    // session forwards via sendUpdateRaw; emulate it:
    const update = await aMgr.encodeStateAsUpdate('n.md')
    aCh.sendUpdateRaw(aMgr.docId('n.md'), update)
    const frame = aSends[aSends.length - 1]![1]

    const bMgr = mkManager()
    const bCh = new CrdtChannel({ manager: bMgr, send: () => {} })
    await bCh.handleFrame('n.md', frame)
    expect((await bMgr.getSharedText('n.md')).toJSON()).toContain('merged-content')
  })

  it('does not reply to a STEP2/UPDATE frame (length<=1 gate)', async () => {
    const mgr = mkManager()
    const send = vi.fn()
    const ch = new CrdtChannel({ manager: mgr, send })
    const other = mkManager()
    const t = await other.getSharedText('n.md')
    t.insert(0, 'x')
    const update = await other.encodeStateAsUpdate('n.md')
    const tmp = new CrdtChannel({ manager: other, send: (_id, f) => ch.handleFrame('n.md', f) })
    tmp.sendUpdateRaw(other.docId('n.md'), update)
    expect(send).not.toHaveBeenCalled() // an UPDATE frame produces an empty reply
  })
})
