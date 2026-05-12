import { PanelLeftClose, PanelLeftOpen } from 'lucide-react'
import { lazy, Suspense, useState } from 'react'
import { Link, NavLink, Outlet } from 'react-router'
import { Button } from '@/components/ui/button'
import { config } from '../config'

const isClerk = config.authProvider === 'clerk'
const ClerkUserButton = isClerk
  ? lazy(() => import('@clerk/clerk-react').then((mod) => ({ default: mod.UserButton })))
  : null
const LocalUserMenu = lazy(() => import('../auth/local-user-menu'))
import { useBillingStatus } from '../api/queries'
import { useChannel } from '../api/use-channel'
import ThemeToggle from '../theme/theme-toggle'
import FolderTree from '../viewer/folder-tree'
import VaultSwitcher from './vault-switcher'

function HeaderLink({ to, label }: { to: string; label: string }) {
  return (
    <NavLink
      to={to}
      className={({ isActive }) =>
        `text-sm transition hover:text-foreground ${
          isActive ? 'font-medium text-foreground' : 'text-muted-foreground'
        }`
      }
    >
      {label}
    </NavLink>
  )
}

export default function AppLayout() {
  const [sidebarOpen, setSidebarOpen] = useState(true)
  useChannel()
  const { data: billing } = useBillingStatus()

  return (
    <>
      {billing?.subscription?.status === 'trialing' && billing.trial_days_remaining > 0 && billing.trial_days_remaining <= 3 && (
        <aside className="bg-amber-50 px-4 py-2 text-center text-sm text-amber-900 dark:bg-amber-950/40 dark:text-amber-100" role="alert">
          {billing.trial_days_remaining} days left in your trial.
        </aside>
      )}
      <section className="flex h-screen flex-col bg-background text-foreground">
        <header className="flex items-center justify-between border-b border-border bg-card px-4 py-2">
          <div className="flex items-center gap-3">
            <Button
              variant="ghost"
              size="icon-sm"
              onClick={() => setSidebarOpen((o) => !o)}
              aria-label={sidebarOpen ? 'Collapse sidebar' : 'Expand sidebar'}
              aria-expanded={sidebarOpen}
              aria-controls="sidebar"
            >
              {sidebarOpen ? <PanelLeftClose /> : <PanelLeftOpen />}
            </Button>
            <Link to="/" className="text-lg font-semibold text-foreground hover:text-foreground/80">
              Engram
            </Link>
          </div>
          <nav className="flex items-center gap-4" aria-label="Main navigation">
            <HeaderLink to="/search" label="Search" />
            <HeaderLink to="/billing" label="Billing" />
            <HeaderLink to="/settings" label="Settings" />
            <ThemeToggle />
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
            } shrink-0 overflow-y-auto border-r border-border bg-card transition-all duration-200`}
          >
            {sidebarOpen && (
              <>
                <VaultSwitcher />
                <FolderTree />
              </>
            )}
          </aside>

          <main className="flex-1 overflow-hidden bg-muted/40 p-6 text-foreground">
            <Outlet />
          </main>
        </section>
      </section>
    </>
  )
}
