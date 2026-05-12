import { useState, useRef, useEffect } from 'react'
import { useAuthAdapter } from './use-auth-adapter'

export default function LocalUserMenu() {
  const { user, logout } = useAuthAdapter()
  const [open, setOpen] = useState(false)
  const menuRef = useRef<HTMLElement>(null)

  useEffect(() => {
    function handleClick(e: MouseEvent) {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setOpen(false)
      }
    }
    document.addEventListener('mousedown', handleClick)
    return () => document.removeEventListener('mousedown', handleClick)
  }, [])

  return (
    <nav className="relative" ref={menuRef} aria-label="Account">
      <button
        onClick={() => setOpen((o) => !o)}
        className="flex h-8 w-8 items-center justify-center rounded-full bg-blue-600 text-sm font-medium text-white"
        aria-label="User menu"
        aria-expanded={open}
        aria-haspopup="menu"
      >
        {user?.email?.[0]?.toUpperCase() ?? '?'}
      </button>

      {open && (
        <menu className="absolute right-0 mt-2 w-48 rounded border border-gray-200 bg-white py-1 shadow-lg dark:border-gray-800 dark:bg-gray-900" role="menu">
          <li role="none">
            <p className="truncate px-4 py-2 text-sm text-gray-700 dark:text-gray-200">{user?.email}</p>
          </li>
          <hr className="border-gray-100 dark:border-gray-800" />
          <li role="none">
            <button
              role="menuitem"
              onClick={async () => { await logout(); setOpen(false) }}
              className="w-full px-4 py-2 text-left text-sm text-gray-700 hover:bg-gray-100 dark:text-gray-200 dark:hover:bg-gray-800"
            >
              Sign out
            </button>
          </li>
        </menu>
      )}
    </nav>
  )
}
