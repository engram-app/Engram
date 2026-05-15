import { Outlet, useLocation } from 'react-router'
import { useAuthAdapter } from '../auth/use-auth-adapter'

export default function OnboardLayout() {
  const { logout } = useAuthAdapter()
  const { pathname } = useLocation()

  const stepNumber = pathname.endsWith('/billing') ? 2 : 1

  return (
    <main className="onboard-layout">
      <header>
        <h1>Welcome to Engram</h1>
        <p>Step {stepNumber} of 2</p>
        <button type="button" onClick={() => logout()}>
          Sign out
        </button>
      </header>
      <section>
        <Outlet />
      </section>
    </main>
  )
}
