import { useState } from 'react'
import { useUser, useReverification } from '@clerk/clerk-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from './section-card'

const inputClass =
  'mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring'

export function EmailSection() {
  const { user, isLoaded } = useUser()
  const [email, setEmail] = useState('')
  const [pending, setPending] = useState<{ attemptVerification: (p: { code: string }) => Promise<unknown> } | null>(null)
  const [code, setCode] = useState('')
  const removeEmail = useReverification((destroy: () => Promise<unknown>) => destroy())
  const setPrimary = useReverification((id: string) => user!.update({ primaryEmailAddressId: id }))

  if (!isLoaded || !user) return null

  async function add() {
    try {
      const created = await user!.createEmailAddress({ email })
      await created.prepareVerification({ strategy: 'email_code' })
      setPending(created)
      toast.success('Verification code sent')
    } catch {
      toast.error('Could not add email')
    }
  }

  async function verify() {
    try {
      await pending!.attemptVerification({ code })
      setPending(null)
      setEmail('')
      setCode('')
      toast.success('Email verified')
    } catch {
      toast.error('Invalid code')
    }
  }

  return (
    <SettingsSectionCard title="Email addresses" description="Add, verify, or remove email addresses.">
      <ul className="space-y-2">
        {user.emailAddresses.map((e) => (
          <li key={e.id} className="flex items-center justify-between gap-2 text-sm">
            <span className="text-foreground">
              {e.emailAddress}
              {e.id === user.primaryEmailAddressId && (
                <span className="ml-2 rounded bg-muted px-1.5 py-0.5 text-xs text-muted-foreground">Primary</span>
              )}
            </span>
            <span className="flex gap-2">
              {e.id !== user.primaryEmailAddressId && (
                <Button variant="ghost" size="sm" onClick={() => setPrimary(e.id)}>Make primary</Button>
              )}
              <Button variant="ghost" size="sm" aria-label={`Remove ${e.emailAddress}`} onClick={() => removeEmail(() => e.destroy())}>Remove</Button>
            </span>
          </li>
        ))}
      </ul>

      {pending ? (
        <div className="mt-4">
          <label className="block text-sm font-medium text-foreground">
            Verification code
            <input className={inputClass} value={code} onChange={(ev) => setCode(ev.target.value)} />
          </label>
          <Button className="mt-2" onClick={verify}>Verify</Button>
        </div>
      ) : (
        <div className="mt-4 flex items-end gap-2">
          <label className="flex-1 block text-sm font-medium text-foreground">
            Add email
            <input className={inputClass} type="email" value={email} onChange={(ev) => setEmail(ev.target.value)} />
          </label>
          <Button onClick={add}>Add</Button>
        </div>
      )}
    </SettingsSectionCard>
  )
}
