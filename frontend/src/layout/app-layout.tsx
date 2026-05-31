import {
  PanelLeftClose,
  PanelLeftOpen,
  PanelRightClose,
  PanelRightOpen,
} from 'lucide-react'
import { useEffect, useState } from 'react'
import { useDefaultLayout, usePanelRef } from 'react-resizable-panels'
import { Outlet } from 'react-router'
import { Button } from '@/components/ui/button'
import {
  ResizableHandle,
  ResizablePanel,
  ResizablePanelGroup,
} from '@/components/ui/resizable'
import { ScrollArea } from '@/components/ui/scroll-area'
import { useMediaQuery } from '@/hooks/use-media-query'
import { useBillingStatus } from '../api/queries'
import { useChannel } from '../api/use-channel'
import { useDemoVaultOptional } from '../onboarding/tour/demo-vault-provider'
import AppHeader from './app-header'
import FolderTree from '../viewer/folder-tree'
import FolderActions from './folder-actions'
import { FolderTreeProvider } from './folder-tree-context'
import MobileLayout from './mobile-layout'
import { RightSidebarProvider, useRightSidebar } from './right-sidebar-context'
import VaultSwitcher from './vault-switcher'

const LAYOUT_PANEL_IDS = ['sidebar', 'main', 'right-sidebar']

function DesktopLayout() {
  const leftRef = usePanelRef()
  const rightRef = usePanelRef()
  const [leftCollapsed, setLeftCollapsed] = useState(false)
  const { content: rightContent, collapsed: rightCollapsed, setCollapsed: setRightCollapsed } =
    useRightSidebar()
  // During the FTUX tour the vault-switcher dropdown opens upward into
  // empty space. Stretch the data-tour anchor so the Joyride spotlight
  // cutout extends over the menu items, not just the trigger row.
  const demoActive = useDemoVaultOptional()?.active === true
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
      <AppHeader />

      <ResizablePanelGroup
        orientation="horizontal"
        defaultLayout={defaultLayout}
        onLayoutChanged={onLayoutChanged}
        className="flex-1"
      >
        <ResizablePanel
          id="sidebar"
          panelRef={leftRef}
          defaultSize="18%"
          minSize="12%"
          maxSize="40%"
          collapsible
          collapsedSize="0%"
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
              <ScrollArea className="flex-1" data-tour="folder-tree">
                <FolderTree />
              </ScrollArea>
              <FolderActions />
              <section className="relative">
                <VaultSwitcher />
                {/*
                  The Joyride spotlight is computed from the target's bounding
                  rect. Use an absolutely-positioned ghost that extends above
                  the VaultSwitcher trigger so the cutout covers the dropdown
                  menu when it opens upward — without taking real layout space
                  (which would shove the FolderActions row up during the tour).
                */}
                {demoActive && (
                  <div
                    data-tour="sidebar-vaults"
                    aria-hidden
                    className="pointer-events-none absolute inset-x-0 bottom-0 -top-24"
                  />
                )}
              </section>
            </div>
          </FolderTreeProvider>
        </ResizablePanel>
        <ResizableHandle withHandle />
        <ResizablePanel id="main" defaultSize="60%" minSize="30%">
          <main
            className="relative h-full overflow-hidden bg-muted/40 p-6 text-foreground"
            data-tour="note-viewer"
          >
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
          defaultSize="22%"
          minSize="12%"
          maxSize="40%"
          collapsible
          collapsedSize="0%"
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
