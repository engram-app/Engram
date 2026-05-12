import { useEffect, useRef, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { type Vault, useVaults } from '../api/queries'
import { setActiveVaultId, useActiveVaultId } from '../api/active-vault'

export default function VaultSwitcher() {
  const { data: vaults, isLoading } = useVaults()
  const activeId = useActiveVaultId()
  const qc = useQueryClient()

  useEffect(() => {
    if (!vaults || vaults.length === 0) return
    const stillValid = activeId != null && vaults.some((v) => v.id === activeId)
    if (stillValid) return
    const fallback = vaults.find((v) => v.is_default) ?? vaults[0]
    if (fallback) setActiveVaultId(fallback.id)
  }, [vaults, activeId])

  if (isLoading) {
    return <p className="px-3 py-2 text-xs text-gray-500 dark:text-gray-400">Loading vaults…</p>
  }
  if (!vaults || vaults.length === 0) {
    return <p className="px-3 py-2 text-xs text-gray-500 dark:text-gray-400">No vaults yet</p>
  }

  const active = vaults.find((v) => v.id === activeId) ?? vaults[0]

  if (vaults.length === 1) {
    return <SingleVaultLabel vault={active!} />
  }

  return (
    <VaultDropdown
      vaults={vaults}
      active={active!}
      onSelect={(id) => {
        setActiveVaultId(id)
        qc.invalidateQueries()
      }}
    />
  )
}

function SingleVaultLabel({ vault }: { vault: Vault }) {
  return (
    <section className="border-b border-gray-200 px-3 py-2 dark:border-gray-800">
      <p className="text-[10px] font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">Vault</p>
      <p className="flex items-center gap-1.5 truncate text-sm font-medium text-gray-900 dark:text-gray-100">
        {vault.encrypted && <LockIcon />}
        {vault.name}
      </p>
    </section>
  )
}

function VaultDropdown({
  vaults,
  active,
  onSelect,
}: {
  vaults: Vault[]
  active: Vault
  onSelect: (id: number) => void
}) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const onClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setOpen(false)
    }
    document.addEventListener('mousedown', onClick)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onClick)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  return (
    <section ref={ref} className="relative border-b border-gray-200 dark:border-gray-800">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="listbox"
        aria-expanded={open}
        className="flex w-full items-center justify-between gap-2 px-3 py-2 text-left hover:bg-gray-100 dark:hover:bg-gray-800"
      >
        <span className="min-w-0 flex-1">
          <span className="block text-[10px] font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">
            Vault
          </span>
          <span className="flex items-center gap-1.5 truncate text-sm font-medium text-gray-900 dark:text-gray-100">
            {active.encrypted && <LockIcon />}
            {active.name}
          </span>
        </span>
        <span className={`text-gray-400 dark:text-gray-500 transition-transform ${open ? 'rotate-180' : ''}`}>▾</span>
      </button>

      {open && (
        <ul
          role="listbox"
          aria-label="Switch vault"
          className="absolute left-2 right-2 top-full z-10 mt-1 max-h-64 overflow-y-auto rounded-md border border-gray-200 bg-white py-1 shadow-lg dark:border-gray-800 dark:bg-gray-900"
        >
          {vaults.map((v) => (
            <li key={v.id} role="option" aria-selected={v.id === active.id}>
              <button
                type="button"
                onClick={() => {
                  onSelect(v.id)
                  setOpen(false)
                }}
                className={`flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm hover:bg-gray-100 dark:hover:bg-gray-800 ${
                  v.id === active.id ? 'font-medium text-gray-900 dark:text-gray-100' : 'text-gray-700 dark:text-gray-200'
                }`}
              >
                <span className="w-3 text-blue-600">{v.id === active.id ? '✓' : ''}</span>
                {v.encrypted && <LockIcon />}
                <span className="truncate">{v.name}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}

function LockIcon() {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 16 16"
      className="h-3 w-3 shrink-0 text-gray-500 dark:text-gray-400"
      fill="currentColor"
    >
      <path d="M8 1a3 3 0 0 0-3 3v3H4a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1V8a1 1 0 0 0-1-1h-1V4a3 3 0 0 0-3-3zm-2 6V4a2 2 0 1 1 4 0v3H6z" />
    </svg>
  )
}
