import { StrictMode, lazy, Suspense } from 'react'
import { createRoot } from 'react-dom/client'
import { RouterProvider } from 'react-router'
import { QueryClientProvider } from '@tanstack/react-query'
import * as Sentry from '@sentry/react'
import { Toaster } from '@/components/ui/sonner'
import { router } from './router'
import { queryClient } from './api/query-client'
import { config } from './config'
import { ThemeProvider } from './theme/theme-provider'
import LoadingScreen from './layout/loading-screen'
import './main.css'

// Sentry — opt-in via VITE_SENTRY_DSN at build time. No-op (zero
// network calls) when the env var is unset, so dev / self-host
// builds are unaffected. Tracing + replay stay off in Tier 1;
// OpenTelemetry → Tempo lands in Tier 2 with explicit sampling.
const sentryDsn = import.meta.env.VITE_SENTRY_DSN
if (sentryDsn) {
  Sentry.init({
    dsn: sentryDsn,
    environment: import.meta.env.MODE,
    release: import.meta.env.VITE_GIT_SHA,
    integrations: [],
    // sendDefaultPii=false (SDK default) keeps cookies + the
    // Authorization header out of breadcrumbs even if the SDK's
    // own scrubbing misses something. Restated for documentation.
    sendDefaultPii: false,
  })
}

// Cloudflare Web Analytics — cookieless RUM beacon. Opt-in via
// VITE_CF_BEACON_TOKEN at build time; no-op when unset so dev /
// self-host builds don't ping the SaaS-side CF analytics account.
// Injected dynamically rather than as a static <script> in
// index.html because the token only exists on the SaaS build path
// (self-host's same bundle would otherwise embed it as a literal).
const cfBeaconToken = import.meta.env.VITE_CF_BEACON_TOKEN
if (cfBeaconToken) {
  const s = document.createElement('script')
  s.defer = true
  s.src = 'https://static.cloudflareinsights.com/beacon.min.js'
  s.setAttribute('data-cf-beacon', JSON.stringify({ token: cfBeaconToken }))
  document.head.appendChild(s)
}

const isClerk = config.authProvider === 'clerk'

const AuthProvider = isClerk
  ? lazy(() => import('./auth/clerk-auth-provider'))
  : lazy(() => import('./auth/local-auth-provider'))

function ErrorFallback() {
  return (
    <main className="grid min-h-screen place-items-center p-6 text-center">
      <section>
        <h1 className="text-xl font-semibold">Something went wrong.</h1>
        <p className="mt-2 text-sm opacity-70">
          The error has been reported. Try reloading; if it keeps happening,
          contact support@engram.page.
        </p>
        <button
          type="button"
          className="mt-4 rounded border px-3 py-1 text-sm"
          onClick={() => window.location.reload()}
        >
          Reload
        </button>
      </section>
    </main>
  )
}

createRoot(document.getElementById('root')!).render(
  <Sentry.ErrorBoundary fallback={ErrorFallback}>
    <StrictMode>
      <ThemeProvider>
        <Suspense fallback={<LoadingScreen />}>
          <AuthProvider>
            <QueryClientProvider client={queryClient}>
              <RouterProvider router={router} />
              <Toaster richColors closeButton />
            </QueryClientProvider>
          </AuthProvider>
        </Suspense>
      </ThemeProvider>
    </StrictMode>
  </Sentry.ErrorBoundary>,
)
