import { Navigate, createBrowserRouter } from 'react-router'
import AuthGuard from './auth/auth-guard'
import SignInPage from './auth/sign-in'
import SignUpPage from './auth/sign-up'
import BillingPage from './billing/billing-page'
import DeviceLinkPage from './device/device-link-page'
import AppLayout from './layout/app-layout'
import ApiKeysPage from './settings/api-keys-page'
import BillingPlaceholder from './settings/billing-placeholder'
import EncryptionPage from './settings/encryption-page'
import SettingsLayout from './settings/settings-layout'
import OAuthAuthorizePage from './oauth/oauth-authorize-page'
import Dashboard from './viewer/dashboard'
import NotePage from './viewer/note-page'
import SearchPage from './viewer/search-page'

export const router = createBrowserRouter(
  [
    // Public routes
    { path: '/sign-in', element: <SignInPage /> },
    { path: '/sign-up', element: <SignUpPage /> },

    // Authenticated routes
    {
      element: <AuthGuard />,
      children: [
        {
          element: <AppLayout />,
          children: [
            { path: '/', element: <Dashboard /> },
            { path: '/note/*', element: <NotePage /> },
            { path: '/search', element: <SearchPage /> },
            { path: '/billing', element: <BillingPage /> },
            {
              path: '/settings',
              element: <SettingsLayout />,
              children: [
                { index: true, element: <Navigate to="api-keys" replace /> },
                { path: 'api-keys', element: <ApiKeysPage /> },
                { path: 'encryption', element: <EncryptionPage /> },
                { path: 'billing', element: <BillingPlaceholder /> },
              ],
            },
          ],
        },
        { path: '/link', element: <DeviceLinkPage /> },
        { path: '/oauth/authorize', element: <OAuthAuthorizePage /> },
      ],
    },
  ],
  { basename: '/app' },
)
