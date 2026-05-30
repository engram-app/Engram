import { useMe } from '@/api/queries'
import { config } from '@/config'
import InvitesTab from './InvitesTab'
import MembersTab from './MembersTab'
import RegistrationTab from './RegistrationTab'

export default function AdminPanel() {
  const { data: me, isLoading } = useMe()

  // Defensive gate — the nav entry is hidden when these don't hold, but a user
  // hitting the URL directly should still get a clean denial rather than a
  // confusing partial page that 403s on every request.
  if (config.authProvider !== 'local') {
    return (
      <p className="text-sm text-muted-foreground">
        Administration is only available on self-hosted instances.
      </p>
    )
  }

  if (isLoading || !me) return <p className="text-sm text-muted-foreground">Loading…</p>

  if (me.role !== 'admin') {
    return (
      <p className="text-sm text-muted-foreground">
        You don't have administrator access on this instance.
      </p>
    )
  }

  return (
    <article className="space-y-8">
      <header>
        <h1 className="text-xl font-semibold text-foreground">Administration</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Manage members, invite links, and who can create accounts on this instance.
        </p>
      </header>

      <section aria-labelledby="members-heading" className="space-y-3">
        <h2 id="members-heading" className="text-sm font-semibold text-foreground">
          Members
        </h2>
        <MembersTab currentUserId={me.id} />
      </section>

      <section aria-labelledby="invites-heading" className="space-y-3">
        <h2 id="invites-heading" className="text-sm font-semibold text-foreground">
          Invites
        </h2>
        <InvitesTab />
      </section>

      <section aria-labelledby="registration-heading" className="space-y-3">
        <h2 id="registration-heading" className="text-sm font-semibold text-foreground">
          Registration
        </h2>
        <RegistrationTab />
      </section>
    </article>
  )
}
