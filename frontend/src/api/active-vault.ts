import { useSyncExternalStore } from 'react'

const STORAGE_KEY = 'engram.activeVaultId'

let activeVaultId: string | null = readStored()
const listeners = new Set<() => void>()

function readStored(): string | null {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return null
    return raw.length > 0 ? raw : null
  } catch {
    return null
  }
}

function writeStored(id: string | null) {
  try {
    if (id == null) localStorage.removeItem(STORAGE_KEY)
    else localStorage.setItem(STORAGE_KEY, id)
  } catch {
    // ignore — private browsing, etc.
  }
}

export function getActiveVaultId(): string | null {
  return activeVaultId
}

export function setActiveVaultId(id: string | null) {
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

export function useActiveVaultId(): string | null {
  return useSyncExternalStore(subscribe, getActiveVaultId, getActiveVaultId)
}
