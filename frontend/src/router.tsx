import { lazy, Suspense, type ReactNode } from 'react'
import { Navigate, createBrowserRouter } from 'react-router'
import AuthGuard from './auth/auth-guard'
import SignInPage from './auth/sign-in'
import SignUpPage from './auth/sign-up'
import WaitlistPage from './auth/waitlist'
import { UpgradeDialogProvider } from './billing/upgrade-dialog-provider'
import type { EngramConfig } from './config'
import AppLayout from './layout/app-layout'
import NotFoundPage from './not-found'
import SettingsLayout from './settings/settings-layout'
import { ROUTES } from './routes'
import OnboardingGate from './onboarding/onboarding-gate'
import OnboardLayout from './onboarding/onboard-layout'
import OnboardRedirect from './onboarding/onboard-redirect'
import { OnboardingShell } from './onboarding/onboarding-shell'
import { Outlet } from 'react-router'

// Route-level code splitting. The viewer stack alone (remark/rehype +
// KaTeX wiring + CodeMirror behind NotePage) dominated a 1.78 MB main
// chunk that even the sign-in page had to parse. Entry surfaces
// (sign-in/up, layouts, guards) stay eager; everything behind navigation
// loads on demand.
const Dashboard = lazy(() => import('./viewer/dashboard'))
const NotePage = lazy(() => import('./viewer/note-page'))
const AttachmentPage = lazy(() => import('./viewer/attachment-page'))
const BillingPage = lazy(() => import('./billing/billing-page'))
const AdminPanel = lazy(() => import('./features/admin/AdminPanel'))
const ResetPasswordPage = lazy(() => import('./features/auth/ResetPasswordPage'))
const DeviceLinkPage = lazy(() => import('./device/device-link-page'))
const ConnectionsPage = lazy(() => import('./settings/connections-page'))
const VaultsPage = lazy(() => import('./settings/vaults-page'))
const OAuthAuthorizePage = lazy(() => import('./oauth/oauth-authorize-page'))
const AgreementPage = lazy(() => import('./onboarding/agreement-page'))
const OnboardBillingPage = lazy(() => import('./onboarding/onboard-billing-page'))
const OnboardToolsPage = lazy(() => import('./onboarding/onboard-tools-page'))
const OnboardVaultPage = lazy(() => import('./onboarding/onboard-vault-page'))

const routeFallback = <p className="p-6 text-muted-foreground">Loading…</p>

function suspended(el: ReactNode) {
  return <Suspense fallback={routeFallback}>{el}</Suspense>
}

// Root layout — mounts the UpgradeDialogProvider INSIDE the router so the
// dialog's `useNavigate` works, and so any nested API call that 402s opens
// the modal via the module-level handler. Wrapping `RouterProvider` from
// `main.tsx` would not give the provider router context.
function RootLayout() {
  return (
    <UpgradeDialogProvider>
      <Outlet />
    </UpgradeDialogProvider>
  )
}

// Router is constructed inside `createAppRouter(config)` so the auth-provider
// and billing-enabled branches can read runtime config. Module-level
// consumers (e.g. clerk-auth-provider's `routerPush`) read `appRouter`,
// which BootstrapGate populates BEFORE first render via `installAppRouter`.
type AppRouter = ReturnType<typeof createBrowserRouter>

let _appRouter: AppRouter | null = null

export function installAppRouter(r: AppRouter) {
  _appRouter = r
}

// Lazy getter used by code paths that need to imperatively navigate
// (e.g. Clerk's routerPush). Throws if invoked before BootstrapGate
// mounted — that would be a wiring regression worth surfacing loudly.
export function getAppRouter(): AppRouter {
  if (!_appRouter) throw new Error('Router accessed before installAppRouter() ran')
  return _appRouter
}

export function createAppRouter(config: EngramConfig): AppRouter {
  // Lazy so Clerk-only code (the account page pulls in @clerk/react hooks)
  // stays out of the main chunk for local self-host builds.
  const AccountPage = lazy(() =>
    config.authProvider === 'clerk'
      ? import('./settings/account-page')
      : import('./settings/account-page-local'),
  )

  return createBrowserRouter(
  [
    {
      element: <RootLayout />,
      children: [
    // Public routes
    { path: ROUTES.SIGN_IN, element: <SignInPage /> },
    { path: ROUTES.SIGN_UP, element: <SignUpPage /> },
    { path: ROUTES.WAITLIST, element: <WaitlistPage /> },
    // Public reset — the one-time token IS the credential.
    { path: '/reset-password', element: suspended(<ResetPasswordPage />) },

    // Authenticated routes
    {
      element: <AuthGuard />,
      children: [
        // Onboarding wizard — itself protected by AuthGuard, but NOT by
        // OnboardingGate (would redirect-loop).
        {
          path: '/onboard',
          element: <OnboardLayout />,
          children: [
            { index: true, element: <OnboardRedirect /> },
            { path: 'agreement', element: suspended(<AgreementPage />) },
            { path: 'billing', element: suspended(<OnboardBillingPage />) },
            { path: 'tools', element: suspended(<OnboardToolsPage />) },
            { path: 'vault', element: suspended(<OnboardVaultPage />) },
          ],
        },

        // /link is reachable mid-onboarding — the wizard's Obsidian branch
        // requires the user to complete device-flow here before progressing.
        // Sits OUTSIDE the OnboardingGate to dodge the redirect-to-/onboard.
        { path: ROUTES.DEVICE_LINK, element: suspended(<DeviceLinkPage />) },

        // OAuth consent — reachable mid-onboarding so an MCP client (e.g.
        // Claude Desktop) initiating a connection during signup can complete
        // the OAuth dance without being bounced to /onboard.
        { path: ROUTES.OAUTH_CONSENT, element: suspended(<OAuthAuthorizePage />) },

        // Dashboard tree — gated by OnboardingGate.
        {
          element: <OnboardingGate />,
          children: [
            {
              // OnboardingShell wraps the dashboard tree so the tour offer,
              // first-vault modal, and checklist only mount on the main app
              // surface — NOT on /settings/*, /device-link, or /oauth.
              element: (
                <OnboardingShell>
                  <Outlet />
                </OnboardingShell>
              ),
              children: [
                {
                  element: <AppLayout />,
                  children: [
                    { path: ROUTES.HOME, element: suspended(<Dashboard />) },
                    { path: '/note/:id', element: suspended(<NotePage />) },
                    { path: '/attachment/*', element: suspended(<AttachmentPage />) },
                    {
                      path: 'settings',
                      element: <SettingsLayout />,
                      children: [
                        {
                          index: true,
                          element: <Navigate to="account" replace />,
                        },
                        {
                          path: 'account',
                          element: (
                            <Suspense
                              fallback={<p className="text-muted-foreground">Loading…</p>}
                            >
                              <AccountPage />
                            </Suspense>
                          ),
                        },
                        { path: 'vaults', element: suspended(<VaultsPage />) },
                        { path: 'connections', element: suspended(<ConnectionsPage />) },
                        { path: 'api-keys', element: <Navigate to="/settings/connections" replace /> },
                        ...(config.billingEnabled
                          ? [{ path: 'billing', element: suspended(<BillingPage />) }]
                          : []),
                        ...(config.authProvider === 'local'
                          ? [{ path: 'admin', element: suspended(<AdminPanel />) }]
                          : []),
                      ],
                    },
                  ],
                },
              ],
            },
          ],
        },
      ],
    },

    // Catch-all (public — typos shouldn't trigger Clerk redirect)
    { path: '*', element: <NotFoundPage /> },
      ],
    },
  ],
  )
}
