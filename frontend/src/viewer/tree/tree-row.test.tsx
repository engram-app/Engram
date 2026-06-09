import { describe, expect, it, vi } from 'vitest'
import { act } from 'react'
import { render, screen, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { TreeRow } from './tree-row'
import type { TreeItem } from './types'
import type { LoaderItem } from './loader'

const folderItem: TreeItem = { kind: 'folder', id: 1, path: 'Projects', name: 'Projects', count: 3 }
const noteItem: TreeItem = { kind: 'note', id: 100, path: 'Projects/a.md', title: 'a', ext: 'md' }
const orgNote: TreeItem = { kind: 'note', id: 101, path: 'Projects/b.org', title: 'b', ext: 'org' }

interface InstanceOverrides {
  data?: TreeItem
  props?: Record<string, unknown>
  isExpanded?: boolean
  isSelected?: boolean
  isFocused?: boolean
  isRenaming?: boolean
  level?: number
  completeRenaming?: () => void
  abortRenaming?: () => void
  renameInputProps?: Record<string, unknown>
}

function mockInstance(overrides: InstanceOverrides = {}) {
  const data = overrides.data ?? folderItem
  const loaderItem: LoaderItem = {
    itemId: `${data.kind === 'folder' ? 'f' : 'n'}:${data.id}`,
    item: data,
    isFolder: data.kind === 'folder',
  }
  const completeRenaming = overrides.completeRenaming ?? vi.fn()
  const abortRenaming = overrides.abortRenaming ?? vi.fn()
  return {
    getId: () => loaderItem.itemId,
    getItemData: () => loaderItem,
    getProps: () => overrides.props ?? {},
    getItemMeta: () => ({ level: overrides.level ?? 0 }),
    isExpanded: () => overrides.isExpanded ?? false,
    isSelected: () => overrides.isSelected ?? false,
    isFocused: () => overrides.isFocused ?? false,
    isRenaming: () => overrides.isRenaming ?? false,
    getRenameInputProps: () => overrides.renameInputProps ?? {},
    getTree: () => ({
      completeRenaming,
      abortRenaming,
      getRenamingValue: () => '',
    }),
  } as never
}

describe('TreeRow', () => {
  it('renders folder name', () => {
    const instance = mockInstance({ data: folderItem })
    render(
      <MemoryRouter>
        <TreeRow instance={instance} />
      </MemoryRouter>,
    )
    expect(screen.getByText('Projects')).toBeInTheDocument()
  })

  it('folder row exposes aria-expanded matching HT state', () => {
    const instance = mockInstance({ data: folderItem, isExpanded: true })
    render(
      <MemoryRouter>
        <TreeRow instance={instance} />
      </MemoryRouter>,
    )
    expect(screen.getByRole('button')).toHaveAttribute('aria-expanded', 'true')
  })

  it('renders note as link to /note/:id', () => {
    const instance = mockInstance({ data: noteItem })
    render(
      <MemoryRouter>
        <TreeRow instance={instance} />
      </MemoryRouter>,
    )
    const link = screen.getByRole('link') as HTMLAnchorElement
    expect(link.getAttribute('href')).toBe('/note/100')
    expect(screen.getByText('a')).toBeInTheDocument()
  })

  it('shows uppercase ext badge for non-md notes', () => {
    const instance = mockInstance({ data: orgNote })
    render(
      <MemoryRouter>
        <TreeRow instance={instance} />
      </MemoryRouter>,
    )
    const badge = screen.getByText('org')
    expect(badge).toBeInTheDocument()
    expect(badge.className).toMatch(/uppercase/)
  })

  it('omits ext badge for md notes', () => {
    const instance = mockInstance({ data: noteItem })
    render(
      <MemoryRouter>
        <TreeRow instance={instance} />
      </MemoryRouter>,
    )
    expect(screen.queryByText('md')).not.toBeInTheDocument()
  })

  it('renders RenameInput when isRenaming is true', () => {
    const instance = mockInstance({ data: folderItem, isRenaming: true })
    render(
      <MemoryRouter>
        <TreeRow instance={instance} />
      </MemoryRouter>,
    )
    expect(screen.getByRole('textbox')).toBeInTheDocument()
  })

  it('aria-selected reflects HT selection state on note link', () => {
    const instance = mockInstance({ data: noteItem, isSelected: true })
    render(
      <MemoryRouter>
        <TreeRow instance={instance} />
      </MemoryRouter>,
    )
    expect(screen.getByRole('link')).toHaveAttribute('aria-selected', 'true')
  })

  it('aria-selected reflects HT selection state on folder button', () => {
    const instance = mockInstance({ data: folderItem, isSelected: true })
    render(
      <MemoryRouter>
        <TreeRow instance={instance} />
      </MemoryRouter>,
    )
    expect(screen.getByRole('button')).toHaveAttribute('aria-selected', 'true')
  })

  it('indents by depth × 12px via getItemMeta().level', () => {
    const instance = mockInstance({ data: folderItem, level: 2 })
    render(
      <MemoryRouter>
        <TreeRow instance={instance} />
      </MemoryRouter>,
    )
    const btn = screen.getByRole('button')
    expect(btn.style.paddingLeft).toBe('28px') // 2 * 12 + 4
  })

  it('invokes onContextMenu with item id + clientX/Y on right-click of a folder row', () => {
    const onContextMenu = vi.fn()
    const instance = mockInstance({ data: folderItem })
    render(
      <MemoryRouter>
        <TreeRow instance={instance} onContextMenu={onContextMenu} />
      </MemoryRouter>,
    )
    fireEvent.contextMenu(screen.getByRole('button'), { clientX: 42, clientY: 99 })
    expect(onContextMenu).toHaveBeenCalledWith('f:1', 42, 99)
  })

  it('invokes onContextMenu with item id + clientX/Y on right-click of a note row', () => {
    const onContextMenu = vi.fn()
    const instance = mockInstance({ data: noteItem })
    render(
      <MemoryRouter>
        <TreeRow instance={instance} onContextMenu={onContextMenu} />
      </MemoryRouter>,
    )
    fireEvent.contextMenu(screen.getByRole('link'), { clientX: 10, clientY: 20 })
    expect(onContextMenu).toHaveBeenCalledWith('n:100', 10, 20)
  })

  it('invokes onLongPress with item id after the long-press delay', () => {
    vi.useFakeTimers()
    const onLongPress = vi.fn()
    const instance = mockInstance({ data: noteItem })
    render(
      <MemoryRouter>
        <TreeRow instance={instance} onLongPress={onLongPress} />
      </MemoryRouter>,
    )
    const link = screen.getByRole('link')
    act(() => {
      fireEvent.pointerDown(link, { clientX: 5, clientY: 5 })
    })
    act(() => {
      vi.advanceTimersByTime(600)
    })
    expect(onLongPress).toHaveBeenCalledWith('n:100')
    vi.useRealTimers()
  })

  it('spreads HT row props onto the rendered element', () => {
    const instance = mockInstance({
      data: folderItem,
      props: { 'data-ht': 'yes', tabIndex: -1 },
    })
    render(
      <MemoryRouter>
        <TreeRow instance={instance} />
      </MemoryRouter>,
    )
    const btn = screen.getByRole('button')
    expect(btn).toHaveAttribute('data-ht', 'yes')
    expect(btn).toHaveAttribute('tabindex', '-1')
  })
})
