import { useEffect, useState } from 'react'
import { fetchSignupRejection, takePendingSignupUser } from './signup-rejection'
import { destructiveAlert } from '@/lib/ui-classes'
import { cn } from '@/lib/utils'

// Shown on the sign-in page after a sign-up was rejected server-side by the
// multi-account block. Self-contained: renders nothing unless a recent pending
// sign-up resolves to a known rejection reason.
export default function SignupRejectionNotice() {
  const [rejected, setRejected] = useState(false)

  useEffect(() => {
    const id = takePendingSignupUser()
    if (!id) return
    let active = true
    fetchSignupRejection(id).then((reason) => {
      if (active && reason === 'duplicate_identity') setRejected(true)
    })
    return () => {
      active = false
    }
  }, [])

  if (!rejected) return null

  return (
    <div
      role="alert"
      className={cn(destructiveAlert, 'mb-4 w-full max-w-sm')}
    >
      <p className="font-medium text-foreground">An account with this email already exists</p>
      <p className="mt-1 text-muted-foreground">
        We couldn’t create a new account because one already exists for this email (or an alias of
        it). Please sign in below instead.
      </p>
    </div>
  )
}
