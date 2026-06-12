import { describe, it, expect } from 'vitest'
import { resolveDropMove } from './drop-redirect'

const ROOT = 'root'

describe('resolveDropMove', () => {
  it('moves a note into a folder destination', () => {
    expect(
      resolveDropMove([{ id: 'n:1', parentId: 'root' }], 'f:projects', ROOT),
    ).toEqual({ dest: 'f:projects', ids: ['n:1'] })
  })

  it('is a no-op when every source is already in the destination (same-folder drop)', () => {
    expect(
      resolveDropMove([{ id: 'n:1', parentId: 'f:projects' }], 'f:projects', ROOT),
    ).toBeNull()
  })

  it('moves only the sources not already in the destination', () => {
    expect(
      resolveDropMove(
        [
          { id: 'n:1', parentId: 'f:projects' },
          { id: 'n:2', parentId: 'root' },
        ],
        'f:projects',
        ROOT,
      ),
    ).toEqual({ dest: 'f:projects', ids: ['n:2'] })
  })

  it('is a no-op when the destination is the vault root (backend cannot move to root)', () => {
    expect(resolveDropMove([{ id: 'n:1', parentId: 'f:a' }], ROOT, ROOT)).toBeNull()
  })

  it('is a no-op when the destination is undefined', () => {
    expect(
      resolveDropMove([{ id: 'n:1', parentId: 'f:a' }], undefined, ROOT),
    ).toBeNull()
  })
})
