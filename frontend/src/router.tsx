import { Navigate, createBrowserRouter } from 'react-router'
import AuthGuard from './auth/auth-guard'
import SignInPage from './auth/sign-in'
import SignUpPage from './auth/sign-up'
import BillingPage from './billing/billing-page'
import DeviceLinkPage from './device/device-link-page'
import AppLayout from './layout/app-layout'
import NotFoundPage from './not-found'
import AppearancePage from './settings/appearance-page'
import ApiKeysPage from './settings/api-keys-page'
import BillingPlaceholder from './settings/billing-placeholder'
import EncryptionPage from './settings/encryption-page'
import SettingsLayout from './settings/settings-layout'
import OAuthAuthorizePage from './oauth/oauth-authorize-page'
import { ROUTES } from './routes'
import Dashboard from './viewer/dashboard'
import NotePage from './viewer/note-page'
import SearchPage from './viewer/search-page'
import OnboardingGate from './onboarding/onboarding-gate'
import OnboardLayout from './onboarding/onboard-layout'
import OnboardRedirect from './onboarding/onboard-redirect'
import AgreementPage from './onboarding/agreement-page'
import OnboardBillingPage from './onboarding/onboard-billing-page'

export const router = createBrowserRouter(
  [
    // Public routes
    { path: ROUTES.SIGN_IN, element: <SignInPage /> },
    { path: ROUTES.SIGN_UP, element: <SignUpPage /> },

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
          ],
        },

        // Dashboard tree — gated by OnboardingGate.
        {
          element: <OnboardingGate />,
          children: [
            {
              element: <AppLayout />,
              children: [
                { path: ROUTES.HOME, element: <Dashboard /> },
                { path: '/note/*', element: <NotePage /> },
                { path: '/search', element: <SearchPage /> },
                { path: '/billing', element: <BillingPage /> },
                {
                  path: '/settings',
                  element: <SettingsLayout />,
                  children: [
                    { index: true, element: <Navigate to="appearance" replace /> },
                    { path: 'appearance', element: <AppearancePage /> },
                    { path: 'api-keys', element: <ApiKeysPage /> },
                    { path: 'encryption', element: <EncryptionPage /> },
                    { path: 'billing', element: <BillingPlaceholder /> },
                  ],
                },
              ],
            },
            { path: ROUTES.DEVICE_LINK, element: <DeviceLinkPage /> },
            { path: ROUTES.OAUTH_CONSENT, element: <OAuthAuthorizePage /> },
          ],
        },
      ],
    },

    // Catch-all (public — typos shouldn't trigger Clerk redirect)
    { path: '*', element: <NotFoundPage /> },
  ],
)
