import { Navigate, Outlet, useLocation } from 'react-router'
import { useAuthAdapter } from './use-auth-adapter'

export default function AuthGuard() {
  const { isLoaded, isSignedIn } = useAuthAdapter()
  const location = useLocation()

  if (!isLoaded) {
    return <p>Loading...</p>
  }

  if (!isSignedIn) {
    const returnTo = location.pathname + location.search + location.hash
    const target =
      returnTo && returnTo !== '/'
        ? `/sign-in?return_to=${encodeURIComponent(returnTo)}`
        : '/sign-in'
    return <Navigate to={target} replace />
  }

  return <Outlet />
}
