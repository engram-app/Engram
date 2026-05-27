import { Link, NavLink } from 'react-router'
import ThemeToggle from '../theme/theme-toggle'
import UserMenu from './user-menu'

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

export default function AppHeader() {
  return (
    <header className="flex items-center justify-between border-b border-border bg-card px-4 py-2">
      <Link
        to="/"
        className="text-lg font-semibold text-foreground hover:text-foreground/80"
      >
        Engram
      </Link>
      <nav className="flex items-center gap-3" aria-label="Main navigation">
        <HeaderLink to="/search" label="Search" />
        <HeaderLink to="/settings" label="Settings" />
        <ThemeToggle />
        <UserMenu />
      </nav>
    </header>
  )
}
