import {
  PanelLeftClose,
  PanelLeftOpen,
  PanelRightClose,
  PanelRightOpen,
} from 'lucide-react'
import { lazy, Suspense, useEffect, useState } from 'react'
import { useDefaultLayout, usePanelRef } from 'react-resizable-panels'
import { Link, NavLink, Outlet } from 'react-router'
import { Button } from '@/components/ui/button'
import {
  ResizableHandle,
  ResizablePanel,
  ResizablePanelGroup,
} from '@/components/ui/resizable'
import { ScrollArea } from '@/components/ui/scroll-area'
import { useMediaQuery } from '@/hooks/use-media-query'
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
import FolderActions from './folder-actions'
import { FolderTreeProvider } from './folder-tree-context'
import MobileLayout from './mobile-layout'
import { RightSidebarProvider, useRightSidebar } from './right-sidebar-context'
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

const LAYOUT_PANEL_IDS = ['sidebar', 'main', 'right-sidebar']

function DesktopLayout() {
  const leftRef = usePanelRef()
  const rightRef = usePanelRef()
  const [leftCollapsed, setLeftCollapsed] = useState(false)
  const { content: rightContent, collapsed: rightCollapsed, setCollapsed: setRightCollapsed } =
    useRightSidebar()
  const { defaultLayout, onLayoutChanged } = useDefaultLayout({
    id: 'engram:app-layout',
    panelIds: LAYOUT_PANEL_IDS,
    storage: typeof window === 'undefined' ? undefined : window.localStorage,
  })

  const toggleLeft = () => {
    const p = leftRef.current
    if (!p) return
    if (p.isCollapsed()) p.expand()
    else p.collapse()
  }

  const toggleRight = () => {
    const p = rightRef.current
    if (!p) return
    if (p.isCollapsed()) p.expand()
    else p.collapse()
  }

  // When a page stops contributing right-sidebar content, force the panel
  // closed so it doesn't sit empty taking up space on the next route.
  useEffect(() => {
    if (rightContent == null) {
      rightRef.current?.collapse()
    } else if (rightRef.current?.isCollapsed()) {
      rightRef.current?.expand()
    }
  }, [rightContent])

  const hasRight = rightContent != null

  return (
    <section className="flex h-screen flex-col bg-background text-foreground">
      <header className="flex items-center justify-between border-b border-border bg-card px-4 py-2">
        <Link to="/" className="text-lg font-semibold text-foreground hover:text-foreground/80">
          Engram
        </Link>
        <nav className="flex items-center gap-3" aria-label="Main navigation">
          <HeaderLink to="/search" label="Search" />
          <HeaderLink to="/billing" label="Billing" />
          <HeaderLink to="/settings" label="Settings" />
          <ThemeToggle />
          <Suspense fallback={null}>
            {ClerkUserButton ? <ClerkUserButton /> : <LocalUserMenu />}
          </Suspense>
        </nav>
      </header>

      <ResizablePanelGroup
        orientation="horizontal"
        defaultLayout={defaultLayout}
        onLayoutChanged={onLayoutChanged}
        className="flex-1"
      >
        <ResizablePanel
          id="sidebar"
          panelRef={leftRef}
          defaultSize={18}
          minSize={12}
          maxSize={40}
          collapsible
          collapsedSize={0}
          onResize={(size) => setLeftCollapsed(size.asPercentage === 0)}
          className="border-r border-border bg-card"
        >
          <FolderTreeProvider>
            <div className="flex h-full flex-col">
              <div className="flex shrink-0 items-center justify-end border-b border-border px-1 py-1">
                <Button
                  variant="ghost"
                  size="icon-sm"
                  onClick={toggleLeft}
                  aria-label="Collapse sidebar"
                  title="Collapse sidebar"
                >
                  <PanelLeftClose />
                </Button>
              </div>
              <ScrollArea className="flex-1">
                <FolderTree />
              </ScrollArea>
              <FolderActions />
              <VaultSwitcher />
            </div>
          </FolderTreeProvider>
        </ResizablePanel>
        <ResizableHandle withHandle />
        <ResizablePanel id="main" defaultSize={60} minSize={30}>
          <main className="relative h-full overflow-hidden bg-muted/40 p-6 text-foreground">
            {leftCollapsed && (
              <Button
                variant="ghost"
                size="icon-sm"
                onClick={toggleLeft}
                aria-label="Expand sidebar"
                title="Expand sidebar"
                className="absolute left-2 top-2 z-10 bg-card/80 backdrop-blur"
              >
                <PanelLeftOpen />
              </Button>
            )}
            {hasRight && rightCollapsed && (
              <Button
                variant="ghost"
                size="icon-sm"
                onClick={toggleRight}
                aria-label="Expand outline"
                title="Expand outline"
                className="absolute right-2 top-2 z-10 bg-card/80 backdrop-blur"
              >
                <PanelRightOpen />
              </Button>
            )}
            <Outlet />
          </main>
        </ResizablePanel>
        <ResizableHandle withHandle />
        <ResizablePanel
          id="right-sidebar"
          panelRef={rightRef}
          defaultSize={22}
          minSize={12}
          maxSize={40}
          collapsible
          collapsedSize={0}
          onResize={(size) => setRightCollapsed(size.asPercentage === 0)}
          className="border-l border-border bg-card"
        >
          <div className="flex h-full flex-col">
            <div className="flex shrink-0 items-center justify-start border-b border-border px-1 py-1">
              <Button
                variant="ghost"
                size="icon-sm"
                onClick={toggleRight}
                aria-label="Collapse outline"
                title="Collapse outline"
              >
                <PanelRightClose />
              </Button>
            </div>
            <ScrollArea className="flex-1">{rightContent}</ScrollArea>
          </div>
        </ResizablePanel>
      </ResizablePanelGroup>
    </section>
  )
}

function AppLayoutInner() {
  useChannel()
  const { data: billing } = useBillingStatus()
  const isDesktop = useMediaQuery('(min-width: 768px)')

  return (
    <>
      {billing?.subscription?.status === 'trialing' && billing.trial_days_remaining > 0 && billing.trial_days_remaining <= 3 && (
        <aside className="bg-amber-50 px-4 py-2 text-center text-sm text-amber-900 dark:bg-amber-950/40 dark:text-amber-100" role="alert">
          {billing.trial_days_remaining} days left in your trial.
        </aside>
      )}
      {isDesktop ? <DesktopLayout /> : <MobileLayout />}
    </>
  )
}

export default function AppLayout() {
  return (
    <RightSidebarProvider>
      <AppLayoutInner />
    </RightSidebarProvider>
  )
}
