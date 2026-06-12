import { api } from '@/api/client'

export type RegistrationMode = 'closed' | 'invite_only' | 'open'

export interface AdminUser {
  id: string
  email: string
  role: 'admin' | 'member'
  display_name: string | null
  suspended: boolean
  created_at: string
  last_active: string | null
}

export interface Invite {
  id: string
  label: string | null
  max_uses: number
  use_count: number
  expires_at: string | null
  inserted_at: string
}

// Paths are relative to /api (client.ts prepends it). Methods return parsed
// JSON; non-2xx throws ApiError — callers catch and branch on err.message.
export const adminApi = {
  getRegistration: () =>
    api.get<{ registration_mode: RegistrationMode }>('/admin/registration'),
  setRegistration: (mode: RegistrationMode) =>
    api.patch<{ registration_mode: RegistrationMode }>('/admin/registration', { mode }),

  listInvites: () => api.get<{ invites: Invite[] }>('/admin/invites'),
  createInvite: (body: { label?: string; max_uses?: number; expires_in_days?: number | null }) =>
    api.post<{ token: string; url: string; invite: Invite }>('/admin/invites', body),
  revokeInvite: (id: string) => api.del<{ ok: true }>(`/admin/invites/${id}`),

  listUsers: () => api.get<{ users: AdminUser[] }>('/admin/users'),
  updateUser: (id: string, body: { role?: 'admin' | 'member'; suspended?: boolean }) =>
    api.patch<{ user: AdminUser }>(`/admin/users/${id}`, body),
  deleteUser: (id: string) => api.del<{ ok: true }>(`/admin/users/${id}`),
  issueReset: (id: string) =>
    api.post<{ token: string; url: string }>(`/admin/users/${id}/password-reset`),

  // Source of current user's id + role for the admin gate (backend Task C5).
  me: () => api.get<{ user: { id: string; email: string; role: 'admin' | 'member' } }>('/me'),
}
