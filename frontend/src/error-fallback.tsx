import * as Sentry from '@sentry/react'
import AuthBackdrop from './layout/auth-backdrop'
import AuthPanel from './layout/auth-panel'
import { Button } from '@/components/ui/button'
import { heading } from '@/lib/ui-classes'

// Top-level crash page rendered by `<Sentry.ErrorBoundary>` in main.tsx.
//
// CRITICAL: this renders OUTSIDE every provider (it replaces the whole app
// subtree), so it must not touch RouterProvider, ThemeProvider, or config
// context. That means a plain <a href> instead of react-router <Link>, a hard
// `window.location.reload()` to re-run the bootstrap chain, and the AuthShell
// header inlined here WITHOUT the ThemeToggle (which needs theme context).
// Brand color tokens are global CSS, so they resolve fine without a provider.
//
// Sentry passes `{ error, componentStack, eventId, resetError }` to the
// fallback; we surface `eventId` as a support reference and `error` (dev only).
//
// `reported` gates the "has been reported" claim + the reference id. Sentry
// hands us an eventId even when no client is initialized (dev / self-host with
// no VITE_SENTRY_DSN), but that id has no transport behind it — claiming the
// crash was reported would be a lie. `getClient()` is truthy only when
// Sentry.init actually ran, so we default to it and let tests inject the flag.
type ErrorFallbackProps = {
  error: unknown
  eventId?: string
  reported?: boolean
}

export default function ErrorFallback({
  error,
  eventId,
  reported = !!Sentry.getClient(),
}: ErrorFallbackProps) {
  const message = error instanceof Error ? error.message : String(error)

  return (
    <main className="flex h-dvh flex-col bg-background text-foreground">
      <header className="flex items-center justify-between border-b border-border bg-card px-4 py-2">
        <span className="flex items-center gap-2 text-lg font-semibold text-foreground">
          <img src="/engram-mark.svg" alt="" className="size-6" />
          Engram
        </span>
      </header>
      <section className="relative flex min-h-0 flex-1 flex-col overflow-hidden">
        <AuthBackdrop />
        <div className="relative z-10 flex min-h-0 flex-1 flex-col overflow-y-auto">
          <AuthPanel className="flex flex-col items-center gap-4 text-center">
          <p className="bg-gradient-to-r from-brand-purple to-primary bg-clip-text text-7xl font-extrabold leading-none tracking-tight text-transparent sm:text-8xl">
            Oops
          </p>
          <h1 className={heading}>Something went wrong</h1>
          <p className="max-w-md text-sm text-muted-foreground">
            An unexpected error broke this page.{reported ? ' It has been reported.' : ''} Try
            reloading — if it keeps happening, contact{' '}
            <a className="underline" href="mailto:support@engram.page">
              support@engram.page
            </a>
            .
          </p>

          {reported && eventId ? (
            <p className="text-xs text-muted-foreground">
              Reference:{' '}
              <code className="rounded bg-muted px-1.5 py-0.5 font-mono">{eventId}</code>
            </p>
          ) : null}

          <div className="mt-2 flex flex-wrap items-center justify-center gap-3">
            <Button type="button" onClick={() => window.location.reload()}>
              Reload
            </Button>
            <Button asChild variant="outline">
              <a href="/">Back to home</a>
            </Button>
          </div>

          {import.meta.env.DEV ? (
            <details className="mt-4 w-full max-w-md rounded-lg border border-destructive/50 bg-destructive/5 p-4 text-left text-sm">
              <summary className="cursor-pointer font-medium">
                Error detail (dev only)
              </summary>
              <pre className="mt-2 overflow-x-auto whitespace-pre-wrap break-words text-xs">
                {message}
                {error instanceof Error && error.stack ? `\n\n${error.stack}` : ''}
              </pre>
            </details>
          ) : null}
          </AuthPanel>
        </div>
      </section>
    </main>
  )
}
