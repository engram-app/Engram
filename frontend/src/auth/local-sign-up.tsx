import { useState, useEffect, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router'
import { ROUTES } from '../routes'
import { useAuthAdapter } from './use-auth-adapter'
import AuthLayout from './auth-layout'
import { Button } from '@/components/ui/button'
import { heading, fieldInput, destructiveAlert } from '@/lib/ui-classes'
import { cn } from '@/lib/utils'

export default function LocalSignUp() {
  const { register, isSignedIn } = useAuthAdapter()
  const navigate = useNavigate()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  // Navigate after auth state propagates (React 18 batching)
  useEffect(() => {
    if (isSignedIn) navigate(ROUTES.HOME, { replace: true })
  }, [isSignedIn, navigate])

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError('')

    if (password !== confirm) {
      setError('Passwords do not match')
      return
    }

    setLoading(true)

    try {
      if (!register) throw new Error('Registration not available for this auth provider')
      await register(email, password)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Registration failed')
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
        <div className="flex flex-col items-center gap-2 text-center">
          <img src="/engram-mark.svg" alt="Engram" className="size-12" />
          <h1 className={heading}>Create your account</h1>
        </div>

        {error && (
          <p
            role="alert"
            className={cn(destructiveAlert, 'p-3 text-foreground')}
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
            className={cn('mt-1 block', fieldInput)}
          />
        </label>

        <label className="block">
          <span className="text-sm font-medium text-foreground">Password</span>
          <input
            type="password"
            required
            minLength={8}
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className={cn('mt-1 block', fieldInput)}
          />
        </label>

        <label className="block">
          <span className="text-sm font-medium text-foreground">Confirm password</span>
          <input
            type="password"
            required
            value={confirm}
            onChange={(e) => setConfirm(e.target.value)}
            className={cn('mt-1 block', fieldInput)}
          />
        </label>

        <Button type="submit" disabled={loading} className="w-full">
          {loading ? 'Creating account…' : 'Create account'}
        </Button>

        <p className="text-center text-sm text-muted-foreground">
          Already have an account?{' '}
          <Link to={ROUTES.SIGN_IN} className="font-medium text-primary hover:underline">
            Sign in
          </Link>
        </p>
      </form>
    </AuthLayout>
  )
}
