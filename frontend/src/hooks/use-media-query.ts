import { useEffect, useState } from 'react'

/**
 * SSR-safe matchMedia hook. Returns `false` on the server (no matchMedia),
 * then re-renders with the real value on mount. Subscribes to changes via
 * `addEventListener('change')` and cleans up on unmount.
 */
export function useMediaQuery(query: string): boolean {
  const getMatch = () => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') {
      return false
    }
    return window.matchMedia(query).matches
  }

  const [matches, setMatches] = useState<boolean>(getMatch)

  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return
    const mql = window.matchMedia(query)
    const handler = (e: MediaQueryListEvent) => setMatches(e.matches)
    // Sync once on mount in case the initial render mismatched (SSR / hydration).
    setMatches(mql.matches)
    mql.addEventListener('change', handler)
    return () => mql.removeEventListener('change', handler)
  }, [query])

  return matches
}
