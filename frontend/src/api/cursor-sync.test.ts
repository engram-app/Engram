import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { QueryClient } from '@tanstack/react-query'

vi.mock('./client', () => ({
  api: { get: vi.fn() },
  ApiError: class ApiError extends Error {
    constructor(
      public status: number,
      message: string,
    ) {
      super(message)
    }
  },
}))

// The cursor-sync requests carry the AMBIENT X-Vault-ID (client.authFetch reads
// the active vault). Mock the active vault so tests can simulate a mid-pull
// vault switch. Defaults to 'v1' (the vault used throughout the suite).
const activeVaultRef = vi.hoisted(() => ({ current: 'v1' }))
vi.mock('./active-vault', () => ({
  getActiveVaultId: () => activeVaultRef.current,
}))

import { api, ApiError } from './client'
import { __resetNoteChangeBatch } from './channel'
import { getCursor, setCursor, encodeCursor, MAX_UUID } from './cursor'
import {
  runCursorSync,
  __resetCursorSyncInflight,
  installCursorSyncTriggers,
} from './cursor-sync'

const get = api.get as unknown as ReturnType<typeof vi.fn>

function mockQueryClient() {
  return {
    invalidateQueries: vi.fn(),
    getQueryData: vi.fn(() => undefined),
  } as unknown as QueryClient & { invalidateQueries: ReturnType<typeof vi.fn> }
}

beforeEach(() => {
  localStorage.clear()
  get.mockReset()
  __resetCursorSyncInflight()
  activeVaultRef.current = 'v1'
  vi.useFakeTimers()
})
afterEach(() => {
  __resetNoteChangeBatch()
  vi.useRealTimers()
  localStorage.clear()
})

describe('runCursorSync — bootstrap (no stored cursor)', () => {
  it('seeds the cursor from the manifest change_seq and applies nothing', async () => {
    get.mockResolvedValueOnce({ change_seq: 7 })
    const qc = mockQueryClient()

    await runCursorSync('v1', qc)

    expect(get).toHaveBeenCalledTimes(1)
    expect(get).toHaveBeenCalledWith('/sync/manifest')
    expect(getCursor('v1')).toBe(encodeCursor(7, MAX_UUID))
    expect(qc.invalidateQueries).not.toHaveBeenCalled()
  })
})

describe('runCursorSync — incremental pull (cursor present)', () => {
  it('pulls fields=meta, invalidates per changed note, and advances the cursor', async () => {
    setCursor('v1', 'tok-0')
    get.mockResolvedValueOnce({
      changes: [
        { type: 'note', id: 'id-1', path: 'docs/a.md', folder: 'docs', deleted: false, seq: 5 },
      ],
      next_cursor: null,
      has_more: false,
    })
    const qc = mockQueryClient()

    await runCursorSync('v1', qc)

    expect(get).toHaveBeenCalledWith('/sync/changes?cursor=tok-0&fields=meta')
    expect(qc.invalidateQueries).toHaveBeenCalledWith({ queryKey: ['note', 'v1', 'id-1'] })
    expect(getCursor('v1')).toBe(encodeCursor(5, 'id-1'))
  })

  it('follows has_more across pages using next_cursor', async () => {
    setCursor('v1', 'tok-0')
    get
      .mockResolvedValueOnce({
        changes: [{ type: 'note', id: 'id-1', path: 'a.md', seq: 1 }],
        next_cursor: 'tok-1',
        has_more: true,
      })
      .mockResolvedValueOnce({
        changes: [{ type: 'note', id: 'id-2', path: 'b.md', seq: 2 }],
        next_cursor: null,
        has_more: false,
      })
    const qc = mockQueryClient()

    await runCursorSync('v1', qc)

    expect(get).toHaveBeenNthCalledWith(1, '/sync/changes?cursor=tok-0&fields=meta')
    expect(get).toHaveBeenNthCalledWith(2, '/sync/changes?cursor=tok-1&fields=meta')
    expect(getCursor('v1')).toBe(encodeCursor(2, 'id-2'))
  })

  it('takes no UI action on attachment rows but still advances past them', async () => {
    setCursor('v1', 'tok-0')
    get.mockResolvedValueOnce({
      changes: [{ type: 'attachment', id: 'att-1', path: 'img/x.png', seq: 9 }],
      next_cursor: null,
      has_more: false,
    })
    const qc = mockQueryClient()

    await runCursorSync('v1', qc)
    vi.advanceTimersByTime(250)

    expect(qc.invalidateQueries).not.toHaveBeenCalled()
    expect(getCursor('v1')).toBe(encodeCursor(9, 'att-1'))
  })

  it('leaves the cursor unchanged on an empty page', async () => {
    setCursor('v1', 'tok-0')
    get.mockResolvedValueOnce({ changes: [], next_cursor: null, has_more: false })
    const qc = mockQueryClient()

    await runCursorSync('v1', qc)

    expect(getCursor('v1')).toBe('tok-0')
  })

  it('reseeds from the manifest when the stored cursor is stale (410)', async () => {
    setCursor('v1', 'stale-tok')
    get
      .mockRejectedValueOnce(new ApiError(410, 'history_expired'))
      .mockResolvedValueOnce({ change_seq: 12 })
    const qc = mockQueryClient()

    await runCursorSync('v1', qc)

    expect(getCursor('v1')).toBe(encodeCursor(12, MAX_UUID))
  })
})

describe('runCursorSync — single-flight per vault', () => {
  it('coalesces concurrent runs for the same vault into one', async () => {
    setCursor('v1', 'tok-0')
    let resolve!: (v: unknown) => void
    get.mockReturnValueOnce(new Promise((r) => (resolve = r)))
    const qc = mockQueryClient()

    const a = runCursorSync('v1', qc)
    const b = runCursorSync('v1', qc)

    resolve({ changes: [], next_cursor: null, has_more: false })
    await Promise.all([a, b])

    expect(get).toHaveBeenCalledTimes(1)
  })
})

describe('runCursorSync — vault switched mid-pull (ambient X-Vault-ID race)', () => {
  it('discards the page and does not advance the cursor when the active vault changed', async () => {
    setCursor('v1', 'tok-0')
    get.mockResolvedValueOnce({
      changes: [{ type: 'note', id: 'id-1', path: 'a.md', seq: 5 }],
      next_cursor: null,
      has_more: false,
    })
    const qc = mockQueryClient()
    // The page resolves under a now-different active vault: client.authFetch
    // sent X-Vault-ID for v2, so this page is v2's data — must not be applied
    // to or persisted against v1.
    activeVaultRef.current = 'v2'

    await runCursorSync('v1', qc)

    expect(qc.invalidateQueries).not.toHaveBeenCalled()
    expect(getCursor('v1')).toBe('tok-0')
  })

  it('does not seed a cursor from a bootstrap fetched under a different vault', async () => {
    get.mockResolvedValueOnce({ change_seq: 99 })
    const qc = mockQueryClient()
    activeVaultRef.current = 'v2'

    await runCursorSync('v1', qc)

    expect(getCursor('v1')).toBeNull()
  })
})

describe('installCursorSyncTriggers', () => {
  it('runs immediately, on window focus, and stops after cleanup', () => {
    const run = vi.fn()
    const qc = mockQueryClient()

    const cleanup = installCursorSyncTriggers('v1', qc, run)
    expect(run).toHaveBeenCalledTimes(1)

    window.dispatchEvent(new Event('focus'))
    expect(run).toHaveBeenCalledTimes(2)

    cleanup()
    window.dispatchEvent(new Event('focus'))
    expect(run).toHaveBeenCalledTimes(2)
  })
})
