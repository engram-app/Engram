import { ChevronRight } from 'lucide-react'
import { Fragment, useEffect, useState } from 'react'
import { toast } from 'sonner'
import { ApiError } from '@/api/client'
import { cn } from '@/lib/utils'
import { adminApi, type AdminUser } from './api'

export default function MembersTab({ currentUserId }: { currentUserId: number }) {
  const [users, setUsers] = useState<AdminUser[]>([])
  const [loading, setLoading] = useState(true)
  const [pendingDelete, setPendingDelete] = useState<number | null>(null)
  // One open at a time keeps the table calm. null = all collapsed.
  const [expandedId, setExpandedId] = useState<number | null>(null)
  // Shown once on issue; cleared by Done. Not persisted anywhere.
  const [resetUrl, setResetUrl] = useState<string | null>(null)

  async function refresh() {
    try {
      const res = await adminApi.listUsers()
      setUsers(res.users)
    } catch (e) {
      toast.error(e instanceof ApiError ? e.message : 'Failed to load users')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    refresh()
  }, [])

  async function run<T>(label: string, fn: () => Promise<T>) {
    try {
      await fn()
      await refresh()
    } catch (e) {
      const raw = e instanceof ApiError ? e.message : 'unknown error'
      const friendly = raw === 'last_admin' ? "Can't remove the last admin." : raw
      toast.error(`${label}: ${friendly}`)
    }
  }

  function toggleRole(u: AdminUser) {
    return run('Update role', () =>
      adminApi.updateUser(u.id, { role: u.role === 'admin' ? 'member' : 'admin' }),
    )
  }

  function toggleSuspend(u: AdminUser) {
    return run('Update status', () => adminApi.updateUser(u.id, { suspended: !u.suspended }))
  }

  function remove(u: AdminUser) {
    return run('Remove user', () => adminApi.deleteUser(u.id)).then(() => setPendingDelete(null))
  }

  async function issueReset(u: AdminUser) {
    try {
      const { url } = await adminApi.issueReset(u.id)
      setResetUrl(url)
    } catch (e) {
      toast.error(e instanceof ApiError ? e.message : 'Reset link failed')
    }
  }

  async function copy(url: string) {
    await navigator.clipboard.writeText(url)
    toast.success('Copied to clipboard')
  }

  function toggleExpanded(id: number) {
    setExpandedId((cur) => (cur === id ? null : id))
    setPendingDelete(null)
  }

  return (
    <section className="space-y-4">
      {resetUrl && (
        <aside
          className="rounded-md border border-primary/40 bg-primary/5 p-3 text-sm"
          role="status"
        >
          <p className="mb-2 font-medium text-foreground">
            One-time reset link (shown once — not stored):
          </p>
          <div className="flex items-center gap-2">
            <code className="flex-1 overflow-x-auto rounded bg-background px-2 py-1 text-xs">
              {resetUrl}
            </code>
            <button
              type="button"
              onClick={() => copy(resetUrl)}
              className="rounded-md border border-border bg-background px-3 py-1 text-xs font-medium hover:bg-accent"
            >
              Copy
            </button>
            <button
              type="button"
              onClick={() => setResetUrl(null)}
              className="rounded-md border border-border bg-background px-3 py-1 text-xs font-medium hover:bg-accent"
            >
              Done
            </button>
          </div>
        </aside>
      )}

      {loading ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : users.length === 0 ? (
        <p className="text-sm text-muted-foreground">No users.</p>
      ) : (
        <table className="w-full text-sm">
          <thead className="text-left text-xs text-muted-foreground">
            <tr>
              <th className="py-3 pl-4 pr-2 font-medium">Email</th>
              <th className="py-3 pr-2 font-medium">Role</th>
              <th className="py-3 pr-2 font-medium">Status</th>
              <th className="py-3 pr-2 font-medium">Last active</th>
              <th className="w-10" />
            </tr>
          </thead>
          <tbody>
            {users.map((u) => {
              const isSelf = u.id === currentUserId
              const isExpanded = expandedId === u.id
              return (
                <Fragment key={u.id}>
                  <tr
                    className={cn(
                      'cursor-pointer border-t border-border transition-colors',
                      isSelf && 'bg-primary/5',
                      isExpanded ? 'bg-accent/50' : 'hover:bg-accent/30',
                    )}
                    onClick={() => toggleExpanded(u.id)}
                  >
                    <td className="py-3 pl-4 pr-2">
                      <span className="text-foreground">{u.email}</span>
                      {isSelf && (
                        <span className="ml-2 rounded-sm bg-primary/15 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wider text-primary">
                          you
                        </span>
                      )}
                    </td>
                    <td className="py-3 pr-2">{u.role}</td>
                    <td className="py-3 pr-2">
                      {u.suspended ? (
                        <span className="text-destructive">suspended</span>
                      ) : (
                        'active'
                      )}
                    </td>
                    <td className="py-3 pr-2">
                      {u.last_active ? new Date(u.last_active).toLocaleDateString() : '—'}
                    </td>
                    <td className="py-3 pl-2 pr-4 text-right">
                      <ChevronRight
                        aria-hidden
                        strokeWidth={2.5}
                        className={cn(
                          'inline-block size-5 text-muted-foreground transition-transform duration-150',
                          isExpanded && 'rotate-90 text-foreground',
                        )}
                      />
                    </td>
                  </tr>
                  {isExpanded && (
                    <tr className="border-t border-border bg-accent/20">
                      <td colSpan={5} className="px-4 py-4">
                        {pendingDelete === u.id ? (
                          <div className="flex flex-wrap items-center justify-between gap-3">
                            <span className="text-xs text-muted-foreground">
                              Remove {u.email} + their vault data?
                            </span>
                            <div className="flex items-center gap-2">
                              <button
                                type="button"
                                onClick={() => setPendingDelete(null)}
                                className="rounded-md border border-border bg-background px-3 py-1.5 text-xs font-medium hover:bg-accent"
                              >
                                Cancel
                              </button>
                              <button
                                type="button"
                                onClick={() => remove(u)}
                                className="rounded-md bg-destructive px-3 py-1.5 text-xs font-semibold text-white shadow-sm hover:bg-destructive/90"
                              >
                                Confirm remove
                              </button>
                            </div>
                          </div>
                        ) : (
                          <div className="flex flex-wrap items-center justify-between gap-3">
                            <div className="flex flex-wrap items-center gap-2">
                              <button
                                type="button"
                                onClick={() => toggleRole(u)}
                                disabled={isSelf}
                                title={isSelf ? 'Cannot change your own role' : undefined}
                                className="rounded-md border border-border bg-background px-3 py-1.5 text-xs font-medium hover:bg-accent disabled:cursor-not-allowed disabled:opacity-50 disabled:hover:bg-background"
                              >
                                {u.role === 'admin' ? 'Demote to member' : 'Promote to admin'}
                              </button>
                              <button
                                type="button"
                                onClick={() => issueReset(u)}
                                className="rounded-md border border-border bg-background px-3 py-1.5 text-xs font-medium hover:bg-accent"
                              >
                                Reset password
                              </button>
                            </div>
                            <div className="flex flex-wrap items-center gap-2">
                              <button
                                type="button"
                                onClick={() => toggleSuspend(u)}
                                disabled={isSelf}
                                title={isSelf ? 'Cannot suspend yourself' : undefined}
                                className={cn(
                                  'rounded-md border border-destructive/40 bg-background px-3 py-1.5 text-xs font-medium text-destructive',
                                  'hover:bg-destructive/10',
                                  'disabled:cursor-not-allowed disabled:border-border disabled:text-muted-foreground disabled:opacity-50 disabled:hover:bg-background',
                                )}
                              >
                                {u.suspended ? 'Unsuspend' : 'Suspend'}
                              </button>
                              {!isSelf && (
                                <button
                                  type="button"
                                  onClick={() => setPendingDelete(u.id)}
                                  className="rounded-md border border-destructive/40 bg-background px-3 py-1.5 text-xs font-medium text-destructive hover:bg-destructive/10"
                                >
                                  Remove…
                                </button>
                              )}
                            </div>
                          </div>
                        )}
                      </td>
                    </tr>
                  )}
                </Fragment>
              )
            })}
          </tbody>
        </table>
      )}
    </section>
  )
}
