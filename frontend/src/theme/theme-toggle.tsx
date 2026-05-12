import { useEffect, useRef, useState } from 'react'
import { useTheme } from './theme-provider'
import type { ThemeChoice } from './storage'

const OPTIONS: ReadonlyArray<{ value: ThemeChoice; label: string }> = [
  { value: 'light', label: 'Light' },
  { value: 'dark', label: 'Dark' },
  { value: 'system', label: 'System' },
]

const BUTTON_LABEL: Record<ThemeChoice, string> = {
  light: 'Theme: light',
  dark: 'Theme: dark',
  system: 'Theme: system',
}

function Icon({ choice }: { choice: ThemeChoice }) {
  if (choice === 'light') {
    return (
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <circle cx="12" cy="12" r="4" />
        <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41" />
      </svg>
    )
  }
  if (choice === 'dark') {
    return (
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
      </svg>
    )
  }
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <rect x="2" y="4" width="20" height="14" rx="2" />
      <path d="M8 22h8M12 18v4" />
    </svg>
  )
}

function Check() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M5 12l5 5L20 7" />
    </svg>
  )
}

export default function ThemeToggle() {
  const { theme, setTheme } = useTheme()
  const [open, setOpen] = useState(false)
  const rootRef = useRef<HTMLDivElement>(null)
  const itemRefs = useRef<Array<HTMLButtonElement | null>>([])

  useEffect(() => {
    if (!open) return

    function handlePointer(e: MouseEvent) {
      if (!rootRef.current?.contains(e.target as Node)) setOpen(false)
    }
    function handleKey(e: KeyboardEvent) {
      if (e.key === 'Escape') {
        setOpen(false)
        return
      }
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault()
        const items = itemRefs.current.filter((el): el is HTMLButtonElement => el !== null)
        if (items.length === 0) return
        const active = document.activeElement as HTMLButtonElement | null
        const idx = active ? items.indexOf(active) : -1
        const next = e.key === 'ArrowDown'
          ? items[(idx + 1) % items.length]
          : items[(idx - 1 + items.length) % items.length]
        next?.focus()
      }
    }

    document.addEventListener('mousedown', handlePointer)
    document.addEventListener('keydown', handleKey)

    const currentIdx = OPTIONS.findIndex((o) => o.value === theme)
    itemRefs.current[currentIdx]?.focus()

    return () => {
      document.removeEventListener('mousedown', handlePointer)
      document.removeEventListener('keydown', handleKey)
    }
  }, [open, theme])

  function pick(value: ThemeChoice) {
    setTheme(value)
    setOpen(false)
  }

  return (
    <div ref={rootRef} className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-label={BUTTON_LABEL[theme]}
        aria-haspopup="menu"
        aria-expanded={open}
        title={BUTTON_LABEL[theme]}
        data-theme-choice={theme}
        className="rounded p-1 text-gray-500 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200"
      >
        <Icon choice={theme} />
      </button>
      {open && (
        <ul
          role="menu"
          aria-label="Theme"
          className="absolute right-0 top-full z-50 mt-1 min-w-36 rounded-md border border-gray-200 bg-white py-1 shadow-lg dark:border-gray-800 dark:bg-gray-900"
        >
          {OPTIONS.map((opt, i) => {
            const active = opt.value === theme
            return (
              <li key={opt.value} role="none">
                <button
                  ref={(el) => {
                    itemRefs.current[i] = el
                  }}
                  type="button"
                  role="menuitem"
                  onClick={() => pick(opt.value)}
                  data-theme-option={opt.value}
                  aria-current={active ? 'true' : undefined}
                  className={
                    active
                      ? 'flex w-full items-center justify-between gap-3 px-3 py-1.5 text-sm font-medium text-gray-900 bg-gray-100 dark:bg-gray-800 dark:text-gray-100'
                      : 'flex w-full items-center justify-between gap-3 px-3 py-1.5 text-sm text-gray-700 hover:bg-gray-100 dark:text-gray-200 dark:hover:bg-gray-800'
                  }
                >
                  <span className="flex items-center gap-2">
                    <Icon choice={opt.value} />
                    {opt.label}
                  </span>
                  {active && <Check />}
                </button>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
