export type ThemeChoice = 'system' | 'light' | 'dark'

const KEY = 'engram:theme'
const VALID: readonly ThemeChoice[] = ['system', 'light', 'dark']

export function getStoredTheme(): ThemeChoice {
  try {
    const raw = window.localStorage.getItem(KEY)
    if (raw && (VALID as readonly string[]).includes(raw)) {
      return raw as ThemeChoice
    }
  } catch {
    // localStorage may throw in private mode or sandboxed contexts
  }
  return 'system'
}

export function setStoredTheme(choice: ThemeChoice): void {
  try {
    window.localStorage.setItem(KEY, choice)
  } catch {
    // best-effort; ignore failures
  }
}
