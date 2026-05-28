import { useState } from 'react'
import { useUser, useReverification } from '@clerk/clerk-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from './section-card'

const inputClass =
  'mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring'

export function PasswordSection() {
  const { user, isLoaded } = useUser()
  const [current, setCurrent] = useState('')
  const [next, setNext] = useState('')
  const update = useReverification(
    (params: { newPassword: string; currentPassword?: string; signOutOfOtherSessions?: boolean }) =>
      user!.updatePassword(params),
  )

  if (!isLoaded || !user) return null
  const hasPassword = user.passwordEnabled

  async function submit() {
    try {
      await update({
        ...(hasPassword ? { currentPassword: current } : {}),
        newPassword: next,
        signOutOfOtherSessions: true,
      })
      setCurrent('')
      setNext('')
      toast.success('Password updated')
    } catch {
      toast.error('Could not update password')
    }
  }

  return (
    <SettingsSectionCard title="Password" description="Set or change your password.">
      {hasPassword && (
        <label className="block text-sm font-medium text-foreground">
          Current password
          <input className={inputClass} type="password" value={current} onChange={(e) => setCurrent(e.target.value)} />
        </label>
      )}
      <label className="mt-4 block text-sm font-medium text-foreground">
        New password
        <input className={inputClass} type="password" value={next} onChange={(e) => setNext(e.target.value)} />
      </label>
      <Button className="mt-4" onClick={submit}>
        {hasPassword ? 'Update password' : 'Set password'}
      </Button>
    </SettingsSectionCard>
  )
}
