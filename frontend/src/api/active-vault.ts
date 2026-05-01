import { useSyncExternalStore } from 'react'

const STORAGE_KEY = 'engram.activeVaultId'

let activeVaultId: number | null = readStored()
const listeners = new Set<() => void>()

function readStored(): number | null {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return null
    const n = Number(raw)
    return Number.isFinite(n) && n > 0 ? n : null
  } catch {
    return null
  }
}

function writeStored(id: number | null) {
  try {
    if (id == null) localStorage.removeItem(STORAGE_KEY)
    else localStorage.setItem(STORAGE_KEY, String(id))
  } catch {
    // ignore — private browsing, etc.
  }
}

export function getActiveVaultId(): number | null {
  return activeVaultId
}

export function setActiveVaultId(id: number | null) {
  if (activeVaultId === id) return
  activeVaultId = id
  writeStored(id)
  listeners.forEach((l) => l())
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

export function useActiveVaultId(): number | null {
  return useSyncExternalStore(subscribe, getActiveVaultId, getActiveVaultId)
}
