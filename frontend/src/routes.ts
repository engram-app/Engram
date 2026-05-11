// SPA route constants. Single source of truth for paths referenced by
// the router, AuthGuard redirects, Clerk's sign-in/up URLs, and any
// inter-page links. Keeps `/sign-in` from drifting in one place and
// silently breaking redirects in another.
export const ROUTES = {
  HOME: '/',
  SIGN_IN: '/sign-in',
  SIGN_UP: '/sign-up',
  DEVICE_LINK: '/link',
  OAUTH_CONSENT: '/oauth/consent',
} as const
