import * as DialogPrimitive from '@radix-ui/react-dialog'
import { Menu, X } from 'lucide-react'
import { useEffect, useState } from 'react'
import { NavLink, Outlet, useNavigate } from 'react-router'
import { Button } from '@/components/ui/button'
import { Dialog, DialogOverlay } from '@/components/ui/dialog'

// Keep this in sync with the duration-200 class on DialogPrimitive.Content
// below — we hold the dialog mounted for one animation cycle after
// onOpenChange(false) so Radix's exit transition plays before we navigate.
const CLOSE_ANIMATION_MS = 200
import { ScrollArea } from '@/components/ui/scroll-area'
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetTitle,
  SheetTrigger,
} from '@/components/ui/sheet'
import { useMe } from '../api/queries'
import { useConfig } from '../config-context'
import { buildSettingsSections, type SettingsSection } from './sections'

function SettingsNavList({
  sections,
  onNavigate,
}: {
  sections: SettingsSection[]
  onNavigate?: () => void
}) {
  return (
    <ul className="space-y-1">
      {sections.map((s) => (
        <li key={s.to}>
          <NavLink
            to={s.to}
            onClick={onNavigate}
            className={({ isActive }) =>
              `block rounded-md px-3 py-2 text-sm transition-colors ${
                isActive
                  ? 'bg-primary/10 font-medium text-primary'
                  : 'text-muted-foreground hover:bg-accent hover:text-accent-foreground'
              }`
            }
          >
            {s.label}
          </NavLink>
        </li>
      ))}
    </ul>
  )
}

export default function SettingsLayout() {
  const config = useConfig()
  const { data: me } = useMe()
  const isAdmin = me?.role === 'admin'
  const sections = buildSettingsSections(config.authProvider, config.billingEnabled, isAdmin)
  const [navOpen, setNavOpen] = useState(false)
  const [open, setOpen] = useState(true)
  const navigate = useNavigate()

  useEffect(() => {
    if (open) return
    const t = setTimeout(() => navigate('/'), CLOSE_ANIMATION_MS)
    return () => clearTimeout(t)
  }, [open, navigate])

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogPrimitive.Portal>
        <DialogOverlay className="bg-background/20 supports-backdrop-filter:backdrop-blur-sm" />
        <DialogPrimitive.Content
          aria-describedby={undefined}
          className="fixed left-1/2 top-1/2 z-50 flex h-[88vh] w-[min(96vw,1100px)] max-w-none -translate-x-1/2 -translate-y-1/2 flex-col overflow-hidden rounded-xl border border-border bg-card shadow-xl duration-200 data-open:animate-in data-open:fade-in-0 data-open:zoom-in-95 data-closed:animate-out data-closed:fade-out-0 data-closed:zoom-out-95"
        >
          <DialogPrimitive.Title className="sr-only">Settings</DialogPrimitive.Title>
          <DialogPrimitive.Close asChild>
            <Button
              variant="ghost"
              size="icon-sm"
              aria-label="Close settings"
              title="Close settings"
              className="absolute right-2 top-2 z-30 text-muted-foreground hover:text-foreground"
            >
              <X className="h-4 w-4" />
            </Button>
          </DialogPrimitive.Close>
        {/* Mobile: section switcher row */}
        <div className="flex items-center gap-2 border-b border-border px-3 py-1.5 md:hidden">
          <Sheet open={navOpen} onOpenChange={setNavOpen}>
            <SheetTrigger asChild>
              <Button
                variant="ghost"
                size="icon"
                aria-label="Open settings sections"
                className="size-9"
              >
                <Menu className="size-5" />
              </Button>
            </SheetTrigger>
            <SheetContent side="left" className="w-64 p-0">
              <SheetTitle className="border-b border-border px-4 py-3 text-sm font-semibold">
                Settings
              </SheetTitle>
              <SheetDescription className="sr-only">Settings sections</SheetDescription>
              <nav aria-label="Settings sections" className="p-3">
                <SettingsNavList sections={sections} onNavigate={() => setNavOpen(false)} />
              </nav>
            </SheetContent>
          </Sheet>
          <span className="text-sm font-semibold text-foreground">Settings</span>
        </div>

        <div className="flex min-h-0 flex-1 flex-col md:flex-row">
          {/* Desktop: persistent side rail */}
          <nav
            aria-label="Settings sections"
            className="hidden h-full w-56 shrink-0 border-r border-border md:block"
          >
            <ScrollArea className="h-full">
              <div className="p-4">
                <h2 className="mb-3 px-3 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                  Settings
                </h2>
                <SettingsNavList sections={sections} />
              </div>
            </ScrollArea>
          </nav>

          <ScrollArea className="min-h-0 min-w-0 flex-1">
            <div className="p-4 sm:p-6">
              <Outlet />
            </div>
          </ScrollArea>
        </div>
        </DialogPrimitive.Content>
      </DialogPrimitive.Portal>
    </Dialog>
  )
}
