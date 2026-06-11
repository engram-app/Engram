import { describe, expect, it, vi } from 'vitest'
import type { QueryClient } from '@tanstack/react-query'
import { handleNoteChanged } from './channel'

function mockQueryClient() {
  return { invalidateQueries: vi.fn() } as unknown as QueryClient & {
    invalidateQueries: ReturnType<typeof vi.fn>
  }
}

describe('handleNoteChanged', () => {
  it('invalidates the per-note query for the upserted path', () => {
    const qc = mockQueryClient()
    handleNoteChanged({ event_type: 'upsert', path: 'foo/bar.md', vault_id: '7' }, qc, '7')
    expect(qc.invalidateQueries).toHaveBeenCalledWith({ queryKey: ['note', '7', 'foo/bar.md'] })
  })

  it('invalidates folder/folderNotes/search lists for the vault', () => {
    const qc = mockQueryClient()
    handleNoteChanged({ event_type: 'upsert', path: 'a.md', vault_id: '7' }, qc, '7')
    const keys = qc.invalidateQueries.mock.calls.map((c) => c[0].queryKey[0])
    expect(keys).toEqual(expect.arrayContaining(['folders', 'folderNotes', 'search']))
  })

  it('invalidates on delete event_type as well', () => {
    const qc = mockQueryClient()
    handleNoteChanged({ event_type: 'delete', path: 'gone.md', vault_id: '7' }, qc, '7')
    expect(qc.invalidateQueries).toHaveBeenCalledWith({ queryKey: ['note', '7', 'gone.md'] })
  })

  it('ignores payloads from a different vault (avoids cross-vault noise)', () => {
    const qc = mockQueryClient()
    handleNoteChanged({ event_type: 'upsert', path: 'a.md', vault_id: '99' }, qc, '7')
    expect(qc.invalidateQueries).not.toHaveBeenCalled()
  })

  it('regression: the bug from #277 — payload has no `kind` field; handler must still fire', () => {
    const qc = mockQueryClient()
    // Server actually sends `event_type`, never `kind`. The old handler gated on
    // `payload.kind === 'note'` and silently dropped every event.
    handleNoteChanged(
      { event_type: 'upsert', path: 'x.md', vault_id: '7', content: 'hello' },
      qc,
      '7',
    )
    expect(qc.invalidateQueries).toHaveBeenCalled()
  })
})
