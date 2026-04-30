import { lazy, Suspense, useState } from 'react'
import { Link, Outlet } from 'react-router'
import { config } from '../config'

const isClerk = config.authProvider === 'clerk'
const ClerkUserButton = isClerk
  ? lazy(() => import('@clerk/clerk-react').then((mod) => ({ default: mod.UserButton })))
  : null
const LocalUserMenu = lazy(() => import('../auth/local-user-menu'))
import { useChannel } from '../api/use-channel'
import { useBillingStatus } from '../api/queries'
import FolderTree from '../viewer/folder-tree'

export default function AppLayout() {
  const [sidebarOpen, setSidebarOpen] = useState(true)
  useChannel()
  const { data: billing } = useBillingStatus()

  return (
    <>
      {billing?.tier === 'none' && (
        <aside className="bg-blue-50 px-4 py-2 text-center text-sm text-blue-800" role="alert">
          Start a free trial to sync your notes.{' '}
          <Link to="/billing" className="font-medium underline">
            Choose a plan
          </Link>
        </aside>
      )}
      {billing?.subscription?.status === 'trialing' && billing.trial_days_remaining > 0 && billing.trial_days_remaining <= 3 && (
        <aside className="bg-amber-50 px-4 py-2 text-center text-sm text-amber-800" role="alert">
          {billing.trial_days_remaining} days left in your trial.
        </aside>
      )}
      <section className="flex h-screen flex-col">
        <header className="flex items-center justify-between border-b border-gray-200 bg-white px-4 py-2">
          <div className="flex items-center gap-3">
            <button
              onClick={() => setSidebarOpen((o) => !o)}
              aria-label={sidebarOpen ? 'Collapse sidebar' : 'Expand sidebar'}
              aria-expanded={sidebarOpen}
              aria-controls="sidebar"
              className="rounded p-1 text-gray-500 hover:bg-gray-100 hover:text-gray-700"
            >
              {sidebarOpen ? '◀' : '▶'}
            </button>
            <Link to="/" className="text-lg font-semibold text-gray-900 hover:text-gray-700">
              Engram
            </Link>
          </div>
          <nav className="flex items-center gap-4" aria-label="Main navigation">
            <Link to="/search" className="text-sm text-gray-600 hover:text-gray-900 hover:underline">
              Search
            </Link>
            <Link to="/billing" className="text-sm text-gray-600 hover:text-gray-900 hover:underline">
              Billing
            </Link>
            <Link to="/settings" className="text-sm text-gray-600 hover:text-gray-900 hover:underline">
              Settings
            </Link>
            <Suspense fallback={null}>
              {ClerkUserButton ? <ClerkUserButton /> : <LocalUserMenu />}
            </Suspense>
          </nav>
        </header>

        <section className="flex flex-1 overflow-hidden">
          <aside
            id="sidebar"
            aria-label="Folder navigation"
            className={`${
              sidebarOpen ? 'w-64' : 'w-0'
            } shrink-0 overflow-y-auto border-r border-gray-200 bg-gray-50 transition-all duration-200`}
          >
            {sidebarOpen && <FolderTree />}
          </aside>

          <main className="flex-1 overflow-y-auto p-6">
            <Outlet />
          </main>
        </section>
      </section>
    </>
  )
}
