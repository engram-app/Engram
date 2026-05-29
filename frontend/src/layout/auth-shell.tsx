import type { ReactNode } from 'react'
import ThemeToggle from '../theme/theme-toggle'

type AuthShellProps = {
  actions?: ReactNode
  navLabel?: string
  children: ReactNode
}

export default function AuthShell({ actions, navLabel, children }: AuthShellProps) {
  return (
    <main className="flex h-screen flex-col bg-background text-foreground">
      <header className="flex items-center justify-between border-b border-border bg-card px-4 py-2">
        <span className="text-lg font-semibold text-foreground">Engram</span>
        <nav className="flex items-center gap-3" aria-label={navLabel}>
          {actions}
          <ThemeToggle />
        </nav>
      </header>
      <section className="relative flex min-h-0 flex-1 flex-col overflow-hidden">
        <div
          className="pointer-events-none absolute inset-0 z-0 overflow-hidden"
          aria-hidden="true"
        >
          <div className="absolute inset-0 grid-overlay opacity-30" />
          <div className="absolute -left-32 -top-32 h-96 w-96 neural-glow-purple opacity-60" />
          <div className="absolute -bottom-32 -right-32 h-96 w-96 neural-glow-cyan opacity-60" />
        </div>
        <div className="relative z-10 flex min-h-0 flex-1 flex-col">{children}</div>
      </section>
    </main>
  )
}
