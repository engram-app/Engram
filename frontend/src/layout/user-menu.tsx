import { lazy, Suspense } from 'react'
import { config } from '../config'

const isClerk = config.authProvider === 'clerk'

const ClerkUserButton = isClerk
  ? lazy(() =>
      import('@clerk/clerk-react').then((mod) => ({ default: mod.UserButton })),
    )
  : null

const LocalUserMenu = lazy(() => import('../auth/local-user-menu'))

export default function UserMenu() {
  return (
    <Suspense fallback={null}>
      {ClerkUserButton ? (
        <ClerkUserButton
          userProfileMode="navigation"
          userProfileUrl="/settings/account"
        />
      ) : (
        <LocalUserMenu />
      )}
    </Suspense>
  )
}
