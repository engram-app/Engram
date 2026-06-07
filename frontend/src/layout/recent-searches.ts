const KEY = 'engram:recent-searches'
const MAX = 8

export function readRecent(): string[] {
  if (typeof window === 'undefined') return []
  try {
    const raw = window.localStorage.getItem(KEY)
    if (!raw) return []
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed.filter((s): s is string => typeof s === 'string').slice(0, MAX) : []
  } catch {
    return []
  }
}

export function pushRecent(query: string): string[] {
  const trimmed = query.trim()
  if (trimmed.length < 2) return readRecent()
  const next = [trimmed, ...readRecent().filter((q) => q !== trimmed)].slice(0, MAX)
  window.localStorage.setItem(KEY, JSON.stringify(next))
  return next
}
