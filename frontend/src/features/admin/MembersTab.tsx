import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { ApiError } from '@/api/client'
import { adminApi, type AdminUser } from './api'

export default function MembersTab({ currentUserId }: { currentUserId: number }) {
  const [users, setUsers] = useState<AdminUser[]>([])
  const [loading, setLoading] = useState(true)
  const [pendingDelete, setPendingDelete] = useState<number | null>(null)
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
      // last_admin → friendlier copy; everything else → backend message.
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
              <th className="py-2 pr-2 font-medium">Email</th>
              <th className="py-2 pr-2 font-medium">Role</th>
              <th className="py-2 pr-2 font-medium">Status</th>
              <th className="py-2 pr-2 font-medium">Last active</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {users.map((u) => (
              <tr key={u.id} className="border-t border-border">
                <td className="py-2 pr-2">{u.email}</td>
                <td className="py-2 pr-2">{u.role}</td>
                <td className="py-2 pr-2">{u.suspended ? 'suspended' : 'active'}</td>
                <td className="py-2 pr-2">
                  {u.last_active ? new Date(u.last_active).toLocaleDateString() : '—'}
                </td>
                <td className="py-2 text-right">
                  {pendingDelete === u.id ? (
                    <span className="inline-flex items-center gap-1">
                      <span className="text-xs text-muted-foreground">
                        Remove {u.email} + their vault data?
                      </span>
                      <button
                        type="button"
                        onClick={() => remove(u)}
                        className="rounded-md bg-destructive px-3 py-1 text-xs font-medium text-destructive-foreground hover:bg-destructive/90"
                      >
                        Confirm
                      </button>
                      <button
                        type="button"
                        onClick={() => setPendingDelete(null)}
                        className="rounded-md border border-border bg-background px-3 py-1 text-xs font-medium hover:bg-accent"
                      >
                        Cancel
                      </button>
                    </span>
                  ) : (
                    <span className="inline-flex gap-1">
                      <button
                        type="button"
                        onClick={() => toggleRole(u)}
                        disabled={u.id === currentUserId}
                        title={u.id === currentUserId ? 'Cannot change your own role' : undefined}
                        className="rounded-md border border-border bg-background px-3 py-1 text-xs font-medium hover:bg-accent disabled:cursor-not-allowed disabled:opacity-50 disabled:hover:bg-background"
                      >
                        {u.role === 'admin' ? 'Demote' : 'Promote'}
                      </button>
                      <button
                        type="button"
                        onClick={() => toggleSuspend(u)}
                        disabled={u.id === currentUserId}
                        title={u.id === currentUserId ? 'Cannot suspend yourself' : undefined}
                        className="rounded-md border border-border bg-background px-3 py-1 text-xs font-medium hover:bg-accent disabled:cursor-not-allowed disabled:opacity-50 disabled:hover:bg-background"
                      >
                        {u.suspended ? 'Unsuspend' : 'Suspend'}
                      </button>
                      <button
                        type="button"
                        onClick={() => issueReset(u)}
                        className="rounded-md border border-border bg-background px-3 py-1 text-xs font-medium hover:bg-accent"
                      >
                        Reset link
                      </button>
                      {u.id !== currentUserId && (
                        <button
                          type="button"
                          onClick={() => setPendingDelete(u.id)}
                          className="rounded-md border border-border bg-background px-3 py-1 text-xs font-medium hover:bg-destructive/10 hover:text-destructive"
                        >
                          Remove
                        </button>
                      )}
                    </span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}
