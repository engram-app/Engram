import { Navigate, Outlet, useLocation } from 'react-router'
import { ROUTES } from '../routes'
import LoadingScreen from '../layout/loading-screen'
import { useAuthAdapter } from './use-auth-adapter'

export default function AuthGuard() {
  const { isLoaded, isSignedIn } = useAuthAdapter()
  const location = useLocation()

  if (!isLoaded) {
    return <LoadingScreen />
  }

  if (!isSignedIn) {
    const returnTo = location.pathname + location.search + location.hash
    const target =
      returnTo && returnTo !== ROUTES.HOME
        ? `${ROUTES.SIGN_IN}?return_to=${encodeURIComponent(returnTo)}`
        : ROUTES.SIGN_IN
    return <Navigate to={target} replace />
  }

  return <Outlet />
}
