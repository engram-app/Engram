import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from 'react'

export type SortKey =
  | 'name-asc'
  | 'name-desc'
  | 'created-desc'
  | 'created-asc'
  | 'modified-desc'
  | 'modified-asc'

type FolderTreeContextValue = {
  isOpen: (path: string) => boolean
  toggle: (path: string) => void
  collapseAll: () => void
  sort: SortKey
  setSort: (next: SortKey) => void
}

const FolderTreeContext = createContext<FolderTreeContextValue | null>(null)

export function FolderTreeProvider({ children }: { children: ReactNode }) {
  const [openSet, setOpenSet] = useState<Set<string>>(() => new Set())
  const [sort, setSort] = useState<SortKey>('name-asc')

  const isOpen = useCallback((path: string) => openSet.has(path), [openSet])
  const toggle = useCallback((path: string) => {
    setOpenSet((prev) => {
      const next = new Set(prev)
      if (next.has(path)) next.delete(path)
      else next.add(path)
      return next
    })
  }, [])
  const collapseAll = useCallback(() => setOpenSet(new Set()), [])

  const value = useMemo(
    () => ({ isOpen, toggle, collapseAll, sort, setSort }),
    [isOpen, toggle, collapseAll, sort],
  )
  return <FolderTreeContext.Provider value={value}>{children}</FolderTreeContext.Provider>
}

export function useFolderTreeState(): FolderTreeContextValue {
  const v = useContext(FolderTreeContext)
  if (!v) throw new Error('useFolderTreeState must be used inside FolderTreeProvider')
  return v
}
