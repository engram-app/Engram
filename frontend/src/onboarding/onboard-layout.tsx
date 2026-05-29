import { Outlet, useLocation } from 'react-router'
import { useAuthAdapter } from '../auth/use-auth-adapter'
import AuthShell from '../layout/auth-shell'

export default function OnboardLayout() {
  const { logout } = useAuthAdapter()
  const { pathname } = useLocation()

  const stepNumber = pathname.endsWith('/billing') ? 2 : 1

  return (
    <AuthShell
      actions={
        <>
          <p className="text-sm text-muted-foreground">Step {stepNumber} of 2</p>
          <button
            type="button"
            onClick={() => logout()}
            className="text-sm text-muted-foreground transition hover:text-foreground"
          >
            Sign out
          </button>
        </>
      }
    >
      <Outlet />
    </AuthShell>
  )
}
