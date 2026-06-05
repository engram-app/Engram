/**
 * Derive the active folder from a router pathname.
 * - "/note/foo/bar.md" → "foo"
 * - "/note/A.md"       → ""    (root note)
 * - "/settings/foo"    → ""    (no note open)
 */
export function deriveActiveFolder(pathname: string): string {
  const PREFIX = '/note/'
  if (!pathname.startsWith(PREFIX)) return ''

  const encoded = pathname.slice(PREFIX.length)
  const segments = encoded.split('/').map((s) => {
    try {
      return decodeURIComponent(s)
    } catch {
      return s
    }
  })

  if (segments.length <= 1) return ''
  return segments.slice(0, -1).join('/')
}
