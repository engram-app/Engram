import { Menu, PanelRightOpen } from 'lucide-react'
import { lazy, Suspense, useState } from 'react'
import { Link, NavLink, Outlet } from 'react-router'
import { Button } from '@/components/ui/button'
import { ScrollArea } from '@/components/ui/scroll-area'
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from '@/components/ui/sheet'
import { config } from '../config'
import ThemeToggle from '../theme/theme-toggle'
import FolderTree from '../viewer/folder-tree'
import { useRightSidebar } from './right-sidebar-context'
import VaultSwitcher from './vault-switcher'

const isClerk = config.authProvider === 'clerk'
const ClerkUserButton = isClerk
  ? lazy(() => import('@clerk/clerk-react').then((mod) => ({ default: mod.UserButton })))
  : null
const LocalUserMenu = lazy(() => import('../auth/local-user-menu'))

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

export default function MobileLayout() {
  const { content: rightContent } = useRightSidebar()
  const [leftOpen, setLeftOpen] = useState(false)
  const [rightOpen, setRightOpen] = useState(false)

  return (
    <section className="flex h-dvh flex-col bg-background text-foreground">
      <header className="sticky top-0 z-20 flex shrink-0 items-center justify-between border-b border-border bg-card px-2 py-2">
        <section className="flex items-center gap-1">
          <Sheet open={leftOpen} onOpenChange={setLeftOpen}>
            <SheetTrigger asChild>
              <Button variant="ghost" size="icon" aria-label="Open files" className="h-11 w-11">
                <Menu />
              </Button>
            </SheetTrigger>
            <SheetContent side="left" className="w-[85vw] max-w-sm p-0">
              <SheetHeader className="border-b border-border px-3 py-2">
                <SheetTitle>Files</SheetTitle>
              </SheetHeader>
              <ScrollArea className="h-[calc(100dvh-3rem)]" onClick={() => setLeftOpen(false)}>
                <VaultSwitcher />
                <FolderTree />
              </ScrollArea>
            </SheetContent>
          </Sheet>
          <Link to="/" className="text-base font-semibold text-foreground">
            Engram
          </Link>
        </section>
        <nav className="flex items-center gap-1" aria-label="Main navigation">
          <HeaderLink to="/search" label="Search" />
          <HeaderLink to="/settings" label="Settings" />
          <ThemeToggle />
          <Suspense fallback={null}>
            {ClerkUserButton ? <ClerkUserButton /> : <LocalUserMenu />}
          </Suspense>
          {rightContent && (
            <Sheet open={rightOpen} onOpenChange={setRightOpen}>
              <SheetTrigger asChild>
                <Button
                  variant="ghost"
                  size="icon"
                  aria-label="Open outline"
                  className="h-11 w-11"
                >
                  <PanelRightOpen />
                </Button>
              </SheetTrigger>
              <SheetContent side="right" className="w-[85vw] max-w-sm p-0">
                <SheetHeader className="border-b border-border px-3 py-2">
                  <SheetTitle>On this page</SheetTitle>
                </SheetHeader>
                <ScrollArea className="h-[calc(100dvh-3rem)]" onClick={() => setRightOpen(false)}>
                  {rightContent}
                </ScrollArea>
              </SheetContent>
            </Sheet>
          )}
        </nav>
      </header>
      <main className="flex-1 overflow-y-auto bg-muted/40 text-foreground">
        <Outlet />
      </main>
    </section>
  )
}
