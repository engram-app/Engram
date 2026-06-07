import { lazy, Suspense } from 'react'
import { Navigate, createBrowserRouter } from 'react-router'
import AuthGuard from './auth/auth-guard'
import SignInPage from './auth/sign-in'
import SignUpPage from './auth/sign-up'
import WaitlistPage from './auth/waitlist'
import BillingPage from './billing/billing-page'
import { UpgradeDialogProvider } from './billing/upgrade-dialog-provider'
import { config } from './config'
import AdminPanel from './features/admin/AdminPanel'
import ResetPasswordPage from './features/auth/ResetPasswordPage'
import DeviceLinkPage from './device/device-link-page'
import AppLayout from './layout/app-layout'
import NotFoundPage from './not-found'
import ConnectionsPage from './settings/connections-page'
import SettingsLayout from './settings/settings-layout'
import VaultsPage from './settings/vaults-page'
import OAuthAuthorizePage from './oauth/oauth-authorize-page'
import { ROUTES } from './routes'
import Dashboard from './viewer/dashboard'
import NotePage from './viewer/note-page'
import OnboardingGate from './onboarding/onboarding-gate'
import OnboardLayout from './onboarding/onboard-layout'
import OnboardRedirect from './onboarding/onboard-redirect'
import AgreementPage from './onboarding/agreement-page'
import OnboardBillingPage from './onboarding/onboard-billing-page'
import OnboardToolsPage from './onboarding/onboard-tools-page'
import OnboardVaultPage from './onboarding/onboard-vault-page'
import { OnboardingShell } from './onboarding/onboarding-shell'
import { Outlet } from 'react-router'

// Lazy so Clerk-only code (the account page pulls in @clerk/react hooks)
// stays out of the main chunk for local self-host builds.
const AccountPage = lazy(() =>
  config.authProvider === 'clerk'
    ? import('./settings/account-page')
    : import('./settings/account-page-local'),
)

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

export const router = createBrowserRouter(
  [
    {
      element: <RootLayout />,
      children: [
    // Public routes
    { path: ROUTES.SIGN_IN, element: <SignInPage /> },
    { path: ROUTES.SIGN_UP, element: <SignUpPage /> },
    { path: ROUTES.WAITLIST, element: <WaitlistPage /> },
    // Public reset — the one-time token IS the credential.
    { path: '/reset-password', element: <ResetPasswordPage /> },

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
            { path: 'agreement', element: <AgreementPage /> },
            { path: 'billing', element: <OnboardBillingPage /> },
            { path: 'tools', element: <OnboardToolsPage /> },
            { path: 'vault', element: <OnboardVaultPage /> },
          ],
        },

        // /link is reachable mid-onboarding — the wizard's Obsidian branch
        // requires the user to complete device-flow here before progressing.
        // Sits OUTSIDE the OnboardingGate to dodge the redirect-to-/onboard.
        { path: ROUTES.DEVICE_LINK, element: <DeviceLinkPage /> },

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
                    { path: ROUTES.HOME, element: <Dashboard /> },
                    { path: '/note/*', element: <NotePage /> },
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
                        { path: 'vaults', element: <VaultsPage /> },
                        { path: 'connections', element: <ConnectionsPage /> },
                        { path: 'api-keys', element: <Navigate to="/settings/connections" replace /> },
                        ...(config.billingEnabled
                          ? [{ path: 'billing', element: <BillingPage /> }]
                          : []),
                        ...(config.authProvider === 'local'
                          ? [{ path: 'admin', element: <AdminPanel /> }]
                          : []),
                      ],
                    },
                  ],
                },
              ],
            },
            { path: ROUTES.OAUTH_CONSENT, element: <OAuthAuthorizePage /> },
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
