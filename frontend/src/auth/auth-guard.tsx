import { Navigate, Outlet, useLocation } from 'react-router'
import LoadingScreen from '../layout/loading-screen'
import { signInRedirectTarget } from './sign-in-redirect'
import { useAuthAdapter } from './use-auth-adapter'

export default function AuthGuard() {
  const { isLoaded, isSignedIn } = useAuthAdapter()
  const location = useLocation()

  if (!isLoaded) {
    return <LoadingScreen />
  }

  if (!isSignedIn) {
    return <Navigate to={signInRedirectTarget(location)} replace />
  }

  return <Outlet />
}
