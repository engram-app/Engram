import { describe, it, expect, vi, beforeEach } from 'vitest'

// Mock the phoenix Socket/Channel so we can assert the crdt: topic join +
// inbound event routing without a real WS.
const channels = new Map<string, any>()
const channelParams = new Map<string, any>()
function mkChannel(topic: string, params?: any) {
  const handlers = new Map<string, (p: any) => void>()
  const ch = {
    topic,
    on: vi.fn((ev: string, cb: (p: any) => void) => handlers.set(ev, cb)),
    push: vi.fn(() => ({ receive: () => ({ receive: () => {} }) })),
    join: vi.fn(() => ({ receive: (_s: string, _cb: any) => ({ receive: () => {} }) })),
    leave: vi.fn(),
    __emit: (ev: string, p: any) => handlers.get(ev)?.(p),
  }
  channels.set(topic, ch)
  channelParams.set(topic, params)
  return ch
}
vi.mock('phoenix', () => ({
  Socket: class {
    constructor(_url: string, _opts: any) {}
    connect() {}
    disconnect() {}
    onOpen(_cb: () => void) {}
    channel(topic: string, params?: any) {
      return mkChannel(topic, params)
    }
  },
  Channel: class {},
}))

const sessionMock = vi.hoisted(() => ({
  startCrdtSession: vi.fn(),
  stopCrdtSession: vi.fn(),
  handleFrame: vi.fn().mockResolvedValue(undefined),
  enroll: vi.fn(),
  notifyCrdtChannelJoined: vi.fn(),
  notifyCrdtChannelError: vi.fn(),
  docPathFromDocId: (id: string) => id.slice(id.indexOf('/') + 1),
  resyncOpenDocs: vi.fn(),
}))
vi.mock('../crdt/session', () => sessionMock)

import { connectChannel, disconnectChannel } from './channel'

describe('crdt channel wiring', () => {
  beforeEach(() => {
    channels.clear()
    channelParams.clear()
    vi.clearAllMocks()
    disconnectChannel()
  })

  it('joins crdt:{userId}:{vaultId} and starts a session', async () => {
    await connectChannel({
      userId: 'u1',
      vaultId: 'v1',
      getToken: async () => 'tok',
      queryClient: {} as any,
    })
    expect(channels.has('crdt:u1:v1')).toBe(true)
    expect(sessionMock.startCrdtSession).toHaveBeenCalledWith(
      expect.objectContaining({ vaultId: 'v1' }),
    )
  })

  it('routes crdt_msg → handleFrame and crdt_doc_ready → enroll', async () => {
    await connectChannel({
      userId: 'u1',
      vaultId: 'v1',
      getToken: async () => 'tok',
      queryClient: {} as any,
    })
    const ch = channels.get('crdt:u1:v1')
    ch.__emit('crdt_msg', { doc_id: 'v1/a.md', b64: 'Zm9v' })
    ch.__emit('crdt_doc_ready', { doc_id: 'v1/a.md' })
    expect(sessionMock.handleFrame).toHaveBeenCalledWith('a.md', 'Zm9v')
    expect(sessionMock.enroll).toHaveBeenCalledWith('a.md')
  })

  it('joins the CRDT channel with crdt_proto: 2', async () => {
    await connectChannel({
      userId: 'u1',
      vaultId: 'v1',
      getToken: async () => 'tok',
      queryClient: {} as any,
    })
    expect(channelParams.get('crdt:u1:v1')).toEqual({ crdt_proto: 2 })
  })
})
