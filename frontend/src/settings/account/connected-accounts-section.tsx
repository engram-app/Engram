import { useUser, useReverification } from '@clerk/clerk-react'
import { isReverificationCancelledError } from '@clerk/clerk-react/errors'
import type { OAuthStrategy } from '@clerk/shared/types'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from './section-card'

const label = (s: string) => s.replace(/^oauth_/, '').replace(/^\w/, (c) => c.toUpperCase())

export function ConnectedAccountsSection({ providers }: { providers: OAuthStrategy[] }) {
  const { user, isLoaded } = useUser()
  const disconnect = useReverification((destroy: () => Promise<unknown>) => destroy())

  if (!isLoaded || !user) return null
  const connected = new Set(user.externalAccounts.map((a) => `oauth_${a.provider}`))

  async function onDisconnect(destroy: () => Promise<unknown>) {
    try {
      await disconnect(destroy)
      await user!.reload()
      toast.success('Account disconnected')
    } catch (e) {
      if (isReverificationCancelledError(e)) return
      toast.error('Could not disconnect account')
    }
  }

  async function connect(strategy: OAuthStrategy) {
    try {
      const acct = await user!.createExternalAccount({
        strategy,
        redirectUrl: `${window.location.origin}/settings/account`,
      })
      const url = acct.verification?.externalVerificationRedirectURL
      if (url) window.location.href = url.toString()
    } catch {
      toast.error('Could not start connection')
    }
  }

  return (
    <SettingsSectionCard title="Connected accounts" description="Link third-party sign-in providers.">
      <ul className="space-y-2">
        {user.externalAccounts.map((a) => (
          <li key={a.id} className="flex items-center justify-between gap-2 text-sm">
            <span className="text-foreground">{label(a.provider)} — {a.emailAddress}</span>
            <Button variant="ghost" size="sm" aria-label={`Disconnect ${label(a.provider)}`} onClick={() => onDisconnect(() => a.destroy())}>
              Disconnect
            </Button>
          </li>
        ))}
      </ul>
      <div className="mt-4 flex flex-wrap gap-2">
        {providers.filter((p) => !connected.has(p)).map((p) => (
          <Button key={p} variant="outline" size="sm" onClick={() => connect(p)}>
            Connect {label(p)}
          </Button>
        ))}
      </div>
    </SettingsSectionCard>
  )
}
