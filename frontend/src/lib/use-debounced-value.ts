import { useEffect, useState } from 'react'

/**
 * Trailing debounce of a changing value. Unlike `useDeferredValue` — which
 * only defers *rendering* and still yields one settled value per keystroke —
 * this emits nothing until the input has been stable for `delayMs`, so
 * consumers keyed on the result (e.g. query keys) fire once per pause
 * instead of once per keystroke.
 */
export function useDebouncedValue<T>(value: T, delayMs: number): T {
  const [debounced, setDebounced] = useState(value)

  useEffect(() => {
    const timer = setTimeout(() => setDebounced(value), delayMs)
    return () => clearTimeout(timer)
  }, [value, delayMs])

  return debounced
}
