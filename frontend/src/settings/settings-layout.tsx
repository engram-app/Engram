import { Menu, X } from 'lucide-react'
import { useState } from 'react'
import { NavLink, Outlet, useNavigate } from 'react-router'
import { Button } from '@/components/ui/button'
import { ScrollArea } from '@/components/ui/scroll-area'
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetTitle,
  SheetTrigger,
} from '@/components/ui/sheet'
import { useMediaQuery } from '@/hooks/use-media-query'
import { useMe } from '../api/queries'
import { config } from '../config'
import { Rail } from '../layout/app-sidebar'
import AuthBackdrop from '../layout/auth-backdrop'
import { RailViewProvider } from '../layout/rail-view-context'
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
  // Role drives the Administration entry (self-host only). Cached by react-query,
  // so other tabs that call useMe() pay no extra request.
  const { data: me } = useMe()
  const isAdmin = me?.role === 'admin'
  const sections = buildSettingsSections(config.authProvider, config.billingEnabled, isAdmin)
  const [navOpen, setNavOpen] = useState(false)
  const isDesktop = useMediaQuery('(min-width: 768px)')
  const navigate = useNavigate()
  const closeSettings = () => navigate('/')

  return (
    <RailViewProvider>
      <section className="flex h-screen bg-background text-foreground">
        {isDesktop && <Rail />}
        <section className="relative min-h-0 flex-1 overflow-hidden">
          {/* Brand grid texture behind the settings panel (matches onboarding). */}
          <AuthBackdrop />
          <div
            onClick={closeSettings}
            onKeyDown={(e) => { if (e.key === 'Escape') closeSettings() }}
            role="button"
            tabIndex={-1}
            aria-label="Close settings"
            className="relative z-10 h-full sm:p-6"
          >
            <div
              onClick={(e) => e.stopPropagation()}
              className="relative mx-auto flex h-full max-w-5xl flex-col overflow-hidden bg-card sm:rounded-xl sm:border sm:border-border sm:shadow-sm md:flex-row"
            >
              <Button
                variant="ghost"
                size="icon-sm"
                aria-label="Close settings"
                title="Close settings"
                onClick={closeSettings}
                className="absolute right-2 top-2 z-30 text-muted-foreground hover:text-foreground"
              >
                <X className="h-4 w-4" />
              </Button>
              {/* Mobile: section switcher in a drawer. */}
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

              {/* Desktop: persistent side rail. */}
              <nav
                aria-label="Settings sections"
                className="hidden w-56 shrink-0 border-r border-border md:block"
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
          </div>
        </section>
      </section>
    </RailViewProvider>
  )
}
