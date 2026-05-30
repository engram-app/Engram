import type { ReactNode } from 'react'
import { useUser, useReverification } from "@clerk/react"
import { isReverificationCancelledError } from '@clerk/react/errors'
import type { OAuthStrategy } from '@clerk/shared/types'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from './section-card'

const GitHubIcon = () => (
  <svg viewBox="0 0 16 16" aria-hidden="true" className="size-4 fill-current">
    <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
  </svg>
)

const GoogleIcon = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true" className="size-4">
    <path fill="#4285F4" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92a5.06 5.06 0 0 1-2.2 3.32v2.76h3.57c2.08-1.92 3.27-4.74 3.27-8.09Z" />
    <path fill="#34A853" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.76c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84A11 11 0 0 0 12 23Z" />
    <path fill="#FBBC05" d="M5.84 14.11a6.6 6.6 0 0 1 0-4.22V7.05H2.18a11 11 0 0 0 0 9.9l3.66-2.84Z" />
    <path fill="#EA4335" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1A11 11 0 0 0 2.18 7.05l3.66 2.84C6.71 7.3 9.14 5.38 12 5.38Z" />
  </svg>
)

const AppleIcon = () => (
  <svg viewBox="0 0 16 16" aria-hidden="true" className="size-4 fill-current">
    <path d="M11.18 8.46c-.02-1.62 1.32-2.4 1.38-2.44-.75-1.1-1.92-1.25-2.34-1.27-1-.1-1.95.59-2.45.59-.5 0-1.29-.57-2.12-.56-1.09.02-2.1.63-2.66 1.61-1.13 1.97-.29 4.88.81 6.48.54.78 1.18 1.66 2.02 1.63.81-.03 1.12-.52 2.1-.52.98 0 1.26.52 2.12.51.88-.02 1.43-.8 1.97-1.58.62-.91.88-1.79.89-1.83-.02-.01-1.71-.66-1.72-2.61ZM9.6 3.69c.44-.54.74-1.28.66-2.02-.64.03-1.41.43-1.87.96-.41.47-.77 1.23-.67 1.95.71.06 1.43-.36 1.88-.89Z" />
  </svg>
)

const PROVIDERS: Record<string, { name: string; icon: ReactNode }> = {
  github: { name: 'GitHub', icon: <GitHubIcon /> },
  google: { name: 'Google', icon: <GoogleIcon /> },
  apple: { name: 'Apple', icon: <AppleIcon /> },
}

function meta(raw: string) {
  const key = raw.replace(/^oauth_/, '')
  return PROVIDERS[key] ?? { name: key.replace(/^\w/, (c) => c.toUpperCase()), icon: null };
}

export function ConnectedAccountsSection({ providers }: { providers: OAuthStrategy[] }) {
  const { user, isLoaded } = useUser()
  const disconnect = useReverification((destroy: () => Promise<unknown>) => destroy())
  // Adding a connection is a reverification-protected action — calling it
  // unwrapped returns a 403 from Clerk. useReverification surfaces the re-auth
  // modal and retries, matching Clerk's documented custom-flow.
  const createExternalAccount = useReverification(
    (params: Parameters<NonNullable<typeof user>['createExternalAccount']>[0]) =>
      user!.createExternalAccount(params),
  )

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
      const acct = await createExternalAccount({
        strategy,
        redirectUrl: `${window.location.origin}/settings/account`,
      })
      const url = acct?.verification?.externalVerificationRedirectURL
      if (url) window.location.href = url.toString()
    } catch (e) {
      if (isReverificationCancelledError(e)) return
      toast.error('Could not start connection')
    }
  }

  const available = providers.filter((p) => !connected.has(p))

  return (
    <SettingsSectionCard title="Connected accounts" description="Link third-party sign-in providers.">
      {user.externalAccounts.length > 0 && (
        <ul className="divide-y divide-border">
          {user.externalAccounts.map((a) => {
            const { name, icon } = meta(a.provider)
            const secondary = a.emailAddress || a.username || 'Connected'
            return (
              <li
                key={a.id}
                className="flex items-center justify-between gap-3 py-3 text-sm first:pt-0 last:pb-0"
              >
                <span className="flex min-w-0 items-center gap-3">
                  <span className="flex size-9 shrink-0 items-center justify-center rounded-md border border-border bg-muted text-foreground">
                    {icon}
                  </span>
                  <span className="flex min-w-0 flex-col">
                    <span className="font-medium text-foreground">{name}</span>
                    <span className="truncate text-xs text-muted-foreground">{secondary}</span>
                  </span>
                </span>
                <Button
                  variant="destructive"
                  size="sm"
                  className="shrink-0"
                  aria-label={`Disconnect ${name}`}
                  onClick={() => onDisconnect(() => a.destroy())}
                >
                  Disconnect
                </Button>
              </li>
            )
          })}
        </ul>
      )}

      {available.length > 0 && (
        <div className="mt-4 flex flex-wrap gap-2">
          {available.map((p) => {
            const { name, icon } = meta(p)
            return (
              <Button key={p} variant="outline" size="sm" className="gap-2" onClick={() => connect(p)}>
                {icon}
                Connect {name}
              </Button>
            )
          })}
        </div>
      )}
    </SettingsSectionCard>
  )
}
