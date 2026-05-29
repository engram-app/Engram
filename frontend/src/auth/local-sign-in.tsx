import { useState, useEffect, type FormEvent } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router'
import { ROUTES } from '../routes'
import { safeReturnTo } from './safe-return-to'
import { useAuthAdapter } from './use-auth-adapter'
import AuthLayout from './auth-layout'
import { Button } from '@/components/ui/button'

const inputClass =
  'mt-1 block w-full rounded-lg border border-input bg-background px-3 py-2 text-sm text-foreground outline-none transition-colors focus-visible:border-primary'

export default function LocalSignIn() {
  const { login, isSignedIn } = useAuthAdapter()
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const returnTo = safeReturnTo(searchParams.get('return_to'))
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  // Navigate after auth state propagates (React 18 batching)
  useEffect(() => {
    if (isSignedIn) navigate(returnTo, { replace: true })
  }, [isSignedIn, navigate, returnTo])

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError('')
    setLoading(true)

    try {
      if (!login) throw new Error('Login not available for this auth provider')
      await login(email, password)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Login failed')
    } finally {
      setLoading(false)
    }
  }

  return (
    <AuthLayout>
      <form
        onSubmit={handleSubmit}
        className="w-full max-w-sm space-y-4 rounded-2xl border border-border bg-card p-6 shadow-sm sm:p-8"
      >
        <h1 className="text-2xl font-bold tracking-tight text-foreground">Sign in to Engram</h1>

        {error && (
          <p
            role="alert"
            className="rounded-lg border border-destructive/50 bg-destructive/5 p-3 text-sm text-foreground"
          >
            {error}
          </p>
        )}

        <label className="block">
          <span className="text-sm font-medium text-foreground">Email</span>
          <input
            type="email"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className={inputClass}
          />
        </label>

        <label className="block">
          <span className="text-sm font-medium text-foreground">Password</span>
          <input
            type="password"
            required
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className={inputClass}
          />
        </label>

        <Button type="submit" disabled={loading} className="w-full">
          {loading ? 'Signing in…' : 'Sign in'}
        </Button>

        <p className="text-center text-sm text-muted-foreground">
          Don't have an account?{' '}
          <Link to={ROUTES.SIGN_UP} className="font-medium text-primary hover:underline">
            Sign up
          </Link>
        </p>
      </form>
    </AuthLayout>
  )
}
