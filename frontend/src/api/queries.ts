import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router'
import { toast } from 'sonner'
import { api, ApiError } from './client'
import { useActiveVaultId } from './active-vault'
import { useDemoVaultOptional } from '../onboarding/tour/demo-vault-provider'
import { collideBump } from '@/lib/collide-bump'

// Encode each path segment but preserve slashes so Phoenix's splat
// routes match. encodeURIComponent on a full path produces %2F, which
// Plug.Static rejects with 400 InvalidPathError before the router runs.
function encodePathSegments(path: string): string {
  return path.split('/').map(encodeURIComponent).join('/')
}

// Types matching backend JSON responses
export interface Folder {
  name: string
  count: number
}

export interface NoteSummary {
  path: string
  title: string
  folder: string
  tags: string[]
  version: number
  mtime: string
  created_at: string
  updated_at: string
}

export interface Note extends NoteSummary {
  content: string
}

export interface SearchResult {
  path: string
  title: string
  folder: string
  heading_path: string | null
  snippet: string
  score: number
  match_count: number
}

export interface User {
  id: number
  email: string
  role: 'admin' | 'member'
  display_name: string | null
}

// Query hooks

export function useFolders() {
  const vaultId = useActiveVaultId()
  const demo = useDemoVaultOptional()
  const query = useQuery({
    queryKey: ['folders', vaultId],
    queryFn: () => api.get<{ folders: Folder[] }>('/folders'),
    select: (data) => data.folders,
    enabled: !demo?.active,
  })
  if (demo?.active) {
    const data: Folder[] = demo.folders.map((f) => ({
      name: f.path,
      count: demo.notes.filter((n) => n.folder_id === f.id).length,
    }))
    return { ...query, data, isLoading: false, isFetching: false, error: null }
  }
  return query
}

export function useFolderNotes(folder: string, options?: { enabled?: boolean }) {
  const vaultId = useActiveVaultId()
  const demo = useDemoVaultOptional()
  const query = useQuery({
    queryKey: ['folderNotes', vaultId, folder],
    queryFn: () =>
      api.get<{ notes: NoteSummary[] }>(`/folders/list?folder=${encodeURIComponent(folder)}`),
    select: (data) => data.notes,
    enabled: !demo?.active && (options?.enabled ?? folder.length > 0),
  })
  if (demo?.active) {
    const matchFolder = demo.folders.find((f) => f.path === folder)
    const notes: NoteSummary[] = matchFolder
      ? demo.notes
          .filter((n) => n.folder_id === matchFolder.id)
          .map((n) => ({
            path: n.path,
            title: n.title,
            folder: matchFolder.path,
            tags: [],
            version: 1,
            mtime: new Date().toISOString(),
            created_at: new Date().toISOString(),
            updated_at: new Date().toISOString(),
          }))
      : []
    return { ...query, data: notes, isLoading: false, isFetching: false, error: null }
  }
  return query
}

export function useNote(path: string) {
  const vaultId = useActiveVaultId()
  const demo = useDemoVaultOptional()
  const query = useQuery({
    queryKey: ['note', vaultId, path],
    queryFn: () => api.get<Note>(`/notes/${encodePathSegments(path)}`),
    enabled: !demo?.active && !!path,
  })
  if (demo?.active) {
    const hit = demo.notes.find((n) => n.path === path)
    if (!hit) return query
    const folder = demo.folders.find((f) => f.id === hit.folder_id)
    const now = new Date().toISOString()
    const data: Note = {
      path: hit.path,
      title: hit.title,
      folder: folder?.path ?? '',
      tags: [],
      version: 1,
      mtime: now,
      created_at: now,
      updated_at: now,
      content: hit.content,
    }
    return { ...query, data, isLoading: false, isFetching: false, error: null }
  }
  return query
}

export function useUpdateNote() {
  const qc = useQueryClient()
  const vaultId = useActiveVaultId()
  return useMutation({
    mutationFn: ({ path, content, version }: { path: string; content: string; version?: number }) =>
      api.post<{ note: Note }>('/notes', {
        path,
        content,
        version,
        mtime: Date.now() / 1000,
      }),
    onSuccess: (_data, vars) => {
      qc.invalidateQueries({ queryKey: ['note', vaultId, vars.path] })
      qc.invalidateQueries({ queryKey: ['folderNotes', vaultId] })
    },
  })
}

function encodePathForRouter(path: string): string {
  return path.split('/').map(encodeURIComponent).join('/')
}

export function useCreateNote() {
  const qc = useQueryClient()
  const vaultId = useActiveVaultId()
  const navigate = useNavigate()

  return useMutation<{ path: string }, ApiError, { folder: string }>({
    mutationFn: async ({ folder }) => {
      const existingNotes =
        qc.getQueryData<{ notes: NoteSummary[] }>(['folderNotes', vaultId, folder])?.notes ?? []
      const existingNames = new Set(
        existingNotes.map((n) => {
          const segments = n.path.split('/')
          return segments[segments.length - 1] ?? n.path
        }),
      )

      const MAX_RACES = 5
      for (let attempt = 0; attempt < MAX_RACES; attempt++) {
        const name = collideBump(existingNames, 'Untitled.md', { cap: 1000 })
        const path = folder ? `${folder}/${name}` : name
        try {
          await api.post<{ note: Note }>('/notes', {
            path,
            content: '',
            mtime: Date.now() / 1000,
          })
          return { path }
        } catch (err) {
          if (err instanceof ApiError && err.status === 409) {
            existingNames.add(name)
            continue
          }
          throw err
        }
      }
      throw new ApiError(500, 'useCreateNote: exceeded race retries')
    },
    onSuccess: ({ path }, vars) => {
      qc.invalidateQueries({ queryKey: ['folders', vaultId] })
      qc.invalidateQueries({ queryKey: ['folderNotes', vaultId, vars.folder] })
      navigate(`/note/${encodePathForRouter(path)}`)
    },
    onError: (err) => {
      if (err instanceof ApiError && err.status === 402) {
        toast.error("You've hit your note limit — upgrade to add more.")
      } else if (err instanceof ApiError && err.status === 403) {
        toast.error("You don't have permission to create notes here.")
      } else {
        toast.error("Couldn't create the note. Try again.")
      }
    },
  })
}

export function useCreateFolder() {
  const qc = useQueryClient()
  const vaultId = useActiveVaultId()

  return useMutation<{ folder: string }, ApiError, { parent: string }>({
    mutationFn: async ({ parent }) => {
      const cached = qc.getQueryData<{ folders: Folder[] }>(['folders', vaultId])
      const existingFolders = cached?.folders.map((f) => f.name) ?? []

      // Restrict to direct children of the parent — siblings only.
      const prefix = parent ? `${parent}/` : ''
      const childNames = new Set(
        existingFolders
          .filter((f) => (parent === '' ? !f.includes('/') : f.startsWith(prefix)))
          .map((f) => (parent === '' ? f : f.slice(prefix.length)))
          .map((f) => f.split('/')[0] ?? f),
      )

      const MAX_RACES = 5
      for (let attempt = 0; attempt < MAX_RACES; attempt++) {
        const name = collideBump(childNames, 'Untitled folder', { cap: 1000 })
        const folder = parent ? `${parent}/${name}` : name
        try {
          await api.post<{ folder: { name: string; count: number } }>('/folders', { folder })
          return { folder }
        } catch (err) {
          if (err instanceof ApiError && err.status === 409) {
            childNames.add(name)
            continue
          }
          throw err
        }
      }
      throw new ApiError(500, 'useCreateFolder: exceeded race retries')
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['folders', vaultId] })
    },
    onError: (err) => {
      if (err instanceof ApiError && err.status === 422) {
        toast.error("That folder name isn't allowed.")
      } else if (err instanceof ApiError && err.status === 403) {
        toast.error("You don't have permission to create folders here.")
      } else {
        toast.error("Couldn't create the folder. Try again.")
      }
    },
  })
}

export function useSearch(query: string) {
  const vaultId = useActiveVaultId()
  return useQuery({
    queryKey: ['search', vaultId, query],
    queryFn: () => api.post<{ results: SearchResult[] }>('/search', { query, limit: 20 }),
    select: (data) => data.results,
    enabled: query.length > 0,
  })
}

export function useTags() {
  const vaultId = useActiveVaultId()
  return useQuery({
    queryKey: ['tags', vaultId],
    queryFn: () => api.get<{ tags: string[] }>('/tags'),
    select: (data) => data.tags,
  })
}

export function useMe() {
  return useQuery({
    queryKey: ['me'],
    queryFn: () => api.get<{ user: User }>('/me'),
    select: (data) => data.user,
  })
}

export function useUpdateProfile() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (body: { display_name: string | null }) =>
      api.patch<{ user: User }>('/me', body),
    onSuccess: (data) => {
      qc.setQueryData(['me'], data)
    },
  })
}

export function useDeleteSelf() {
  return useMutation<void, Error, { password: string }>({
    mutationFn: async ({ password }) => {
      await api.del<void>(`/me?password=${encodeURIComponent(password)}`)
    },
  })
}

// Billing types
export interface BillingStatus {
  tier: 'free' | 'none' | 'trial' | 'starter' | 'pro'
  active: boolean
  trial_days_remaining: number
  subscription: {
    status: string
    tier: string
    current_period_end: string
  } | null
  caps: {
    obsidian_connections: number | null
    mcp_connections: number | null
    api_write_enabled: boolean
  }
}

// Billing hooks

export function useBillingStatus() {
  return useQuery({
    queryKey: ['billing', 'status'],
    queryFn: () => api.get<BillingStatus>('/billing/status'),
  })
}

export interface BillingConfig {
  client_token: string
  environment: 'sandbox' | 'production'
  price_ids: {
    starter: { monthly: string; annual: string }
    pro: { monthly: string; annual: string }
  }
  customer_email: string
  custom_data: {
    user_id: number
  }
  // Maximum number of active vaults the user may have, or null for unlimited.
  vaults_cap: number | null
}

export type BillingCadence = 'monthly' | 'annual'

export function useBillingConfig() {
  return useQuery({
    queryKey: ['billing', 'config'],
    queryFn: () => api.get<BillingConfig>('/billing/config'),
    staleTime: Infinity,
  })
}

export interface SubscriptionDetail {
  next_billed_at: string | null
  amount: string | null
  currency: string | null
  billing_cycle: { interval: string; frequency: number } | null
  scheduled_change: { action: string; effective_at: string } | null
}

export interface PaymentMethod {
  type: string | null
  card_brand: string | null
  last4: string | null
  exp_month: number | null
  exp_year: number | null
}

export interface BillingTransaction {
  id: string
  billed_at: string | null
  amount: string | null
  currency: string | null
  status: string
  invoice_id: string | null
}

export interface BillingHistory {
  payment_method: PaymentMethod | null
  transactions: BillingTransaction[]
}

// Live read-through endpoints — only meaningful for users with a Paddle
// subscription (they 404 otherwise), so callers gate with `enabled`.
export function useBillingSubscriptionDetail(enabled: boolean) {
  return useQuery({
    queryKey: ['billing', 'subscription'],
    queryFn: () => api.get<SubscriptionDetail>('/billing/subscription'),
    enabled,
  })
}

export function useBillingHistory(enabled: boolean) {
  return useQuery({
    queryKey: ['billing', 'transactions'],
    queryFn: () => api.get<BillingHistory>('/billing/transactions'),
    enabled,
  })
}

// Onboarding types

export type OnboardingAction =
  | 'tour_offered_taken'
  | 'tour_offered_skipped'
  | 'tour_completed'
  | 'first_vault_created'
  | 'plugin_connected'
  | 'ai_connected'
  | `dismissed:${string}`

export interface OnboardingStatus {
  enabled: boolean
  terms_ok?: boolean
  subscription_ok?: boolean
  profile_complete?: boolean
  // Echoed back once `set_profile/2` has run — drives the personalized
  // setup cards on the dashboard. Absent until the questionnaire is done.
  profile?: OnboardingProfile
  // True when at least one non-deleted vault exists. The fresh-start
  // onboarding path (uses_obsidian=false) gates `next_step: "vault"` on
  // this; Obsidian users short-circuit past the gate (plugin creates the
  // vault on first OAuth sign-in).
  has_vault?: boolean
  current_tos_version?: string
  current_privacy_version?: string
  next_step: OnboardingStep | 'done'
  // Full intended step chain for THIS account at this moment. Self-host
  // returns ["tools","vault"]; hosted returns ["agreement","billing",
  // "tools","vault"]. `:tools` collects the FTUX tool checkboxes; `:vault`
  // owns the obsidian/fresh source pick + first-vault creation. The
  // frontend uses this for "Step X of N" and to reject manual nav to a
  // step not in the chain (e.g. /onboard/agreement on self-host).
  steps: OnboardingStep[]
  // Post-wizard milestone log driving the persistent dashboard checklist.
  actions: OnboardingAction[]
  // Live vault count for checklist gating + tour decisions.
  vault_count: number
}

export type OnboardingStep = 'agreement' | 'billing' | 'tools' | 'vault'

// Partial mid-flow: the `:tools` step POSTs `tools` first, the `:vault`
// step POSTs `uses_obsidian` after. `completed_at` only stamps once both
// have landed — until then, treat absent fields as "user hasn't answered
// that screen yet."
export interface OnboardingProfile {
  uses_obsidian?: boolean
  tools?: string[]
  completed_at?: string
}

// Onboarding hooks

export function useOnboardingStatus() {
  return useQuery({
    queryKey: ['onboarding', 'status'],
    queryFn: () => api.get<OnboardingStatus>('/onboarding/status'),
    staleTime: Infinity,
    refetchOnWindowFocus: true,
  })
}

export function useRecordOnboardingAction() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (action: OnboardingAction) =>
      api.post<{ status: string }>('/onboarding/actions', { action }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['onboarding', 'status'] }),
    retry: 3,
  })
}

export function useAcceptTerms() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (body: {
      tos_version: string
      tos_hash: string
      privacy_version: string
      privacy_hash: string
    }) => api.post<{ version: string; accepted_at: string }>('/onboarding/accept-terms', body),
    // `await` is load-bearing: callers (agreement-page) navigate to /onboard
    // immediately after the mutation resolves, and OnboardRedirect reads cached
    // status to pick the next step. Without awaiting the refetch, the stale
    // `next_step: 'agreement'` bounces the user back to the same page and
    // they're forced to accept twice. invalidateQueries returns a Promise that
    // settles when active queries have refetched — await it.
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: ['onboarding', 'status'] })
    },
  })
}

// Partial body — the `:tools` screen POSTs `{ tools }`, the `:vault` screen
// POSTs `{ uses_obsidian }`. Either field may be present (or both, on a
// one-shot completion). Backend `set_profile/2` merges into the JSONB
// column and stamps `completed_at` once both halves have landed.
export function useSetOnboardingProfile() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (body: { uses_obsidian?: boolean; tools?: string[] }) =>
      api.patch<OnboardingProfile>('/onboarding/profile', body),
    // AWAIT the invalidation so mutateAsync resolves only after
    // ['onboarding','status'] has refetched. Without the await,
    // OnboardingGate reads the still-cached next_step (e.g. "tools")
    // immediately after navigate and bounces back here.
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: ['onboarding', 'status'] })
    },
  })
}

// API key types

export interface ApiKey {
  id: number
  name: string
  created_at: string
  last_used: string | null
}

export interface CreatedApiKey {
  id: number
  name: string
  key: string
}

// API key hooks

export function useApiKeys() {
  return useQuery({
    queryKey: ['api-keys'],
    queryFn: () => api.get<{ keys: ApiKey[] }>('/api-keys'),
    select: (data) => data.keys,
  })
}

export function useCreateApiKey() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (name: string) => api.post<CreatedApiKey>('/api-keys', { name }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['api-keys'] }),
  })
}

export function useRevokeApiKey() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: number) => api.del<{ deleted: boolean }>(`/api-keys/${id}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['api-keys'] }),
  })
}

// ── Connections ─────────────────────────────────────────────

export type ConnectionKind = 'obsidian' | 'mcp' | 'pat'

export interface Connection {
  kind: ConnectionKind
  client_id: string | null
  key_id: number | null
  name: string | null
  software_id: string | null
  software_version: string | null
  verified: boolean
  logo: string | null
  vault_id: number | null
  vault_name: string | null
  scope: string | null
  last_used_at: string | null
  connected_at: string | null
  first_user_agent: string | null
  first_ip: string | null
  redirect_uris: string[]
}

export interface CapErrorBody {
  error: 'connection_cap_reached'
  kind: 'obsidian' | 'mcp'
  current: number
  limit: number
  upgrade_url: string
}

export interface PatDisabledErrorBody {
  error: 'pat_disabled_on_free'
  upgrade_url: string
}

export function useConnections(opts?: { enabled?: boolean }) {
  return useQuery({
    queryKey: ['connections'],
    queryFn: () => api.get<Connection[]>('/connections'),
    enabled: opts?.enabled ?? true,
  })
}

export function useCreatePat() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (name: string) =>
      api.post<{ key: string; id: number; name: string }>('/connections/pat', { name }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['connections'] })
      qc.invalidateQueries({ queryKey: ['api-keys'] }) // legacy queries also need refresh
    },
  })
}

export function useRevokeOauthConnection() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (clientId: string) => api.del(`/connections/oauth/${clientId}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['connections'] }),
  })
}

export function useRevokeDeviceConnection() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (familyId: string) => api.del(`/connections/device/${familyId}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['connections'] }),
  })
}

export function useRevokePat() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: number) => api.del(`/connections/pat/${id}`),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['connections'] })
      qc.invalidateQueries({ queryKey: ['api-keys'] })
    },
  })
}

// Vault types (encryption fields are the ones we care about for settings)

export type EncryptionStatus = 'none' | 'encrypting' | 'encrypted' | 'decrypt_pending'

export interface Vault {
  id: number
  name: string
  description: string | null
  slug: string
  is_default: boolean
  created_at: string
  encrypted: boolean
  encryption_status: EncryptionStatus
  encrypted_at: string | null
  decrypt_requested_at: string | null
  last_toggle_at: string | null
  cooldown_days: number | null
  deleted_at?: string | null
  purge_at?: string | null
  note_count?: number
  attachment_count?: number
}

export interface EncryptionProgress {
  processed: number
  total: number
  status: EncryptionStatus
  started_at: string | null
}

// Vault hooks

export function useVaults() {
  const demo = useDemoVaultOptional()
  const query = useQuery({
    queryKey: ['vaults'],
    queryFn: () => api.get<{ vaults: Vault[] }>('/vaults'),
    select: (data) => data.vaults,
    enabled: !demo?.active,
  })
  if (demo?.active && demo.vault) {
    const base = {
      description: null,
      created_at: new Date(0).toISOString(),
      encrypted: false,
      encryption_status: 'none' as const,
      encrypted_at: null,
      decrypt_requested_at: null,
      last_toggle_at: null,
      cooldown_days: null,
      note_count: demo.notes.length,
    }
    // Two fake vaults so the VaultSwitcher renders its dropdown — the tour's
    // first step is gated on a real switch between them. Notes are shared.
    const vaults: Vault[] = [
      { ...base, id: -1, name: demo.vault.name, slug: demo.vault.id, is_default: true },
      { ...base, id: -2, name: 'Personal', slug: `${demo.vault.id}-personal`, is_default: false },
    ]
    return { ...query, data: vaults, isLoading: false, isPending: false, error: null } as typeof query
  }
  return query
}

export function useEncryptVault() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: number) => api.post<{ vault: Vault }>(`/vaults/${id}/encrypt`),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['vaults'] })
      qc.invalidateQueries({ queryKey: ['encryption-progress'] })
    },
  })
}

export function useEncryptionProgress(vaultId: number | undefined, enabled: boolean) {
  return useQuery({
    queryKey: ['encryption-progress', vaultId],
    queryFn: () => api.get<EncryptionProgress>(`/vaults/${vaultId}/encryption_progress`),
    enabled: enabled && vaultId !== undefined,
    refetchInterval: enabled ? 3000 : false,
  })
}

export function useDeletedVaults() {
  return useQuery({
    queryKey: ['vaults', 'deleted'],
    queryFn: () => api.get<{ vaults: Vault[] }>('/vaults?deleted=true'),
    select: (data) => data.vaults,
  })
}

export function useDeleteVault() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: number) => api.del<{ deleted: boolean }>(`/vaults/${id}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['vaults'] }),
  })
}

export function useRestoreVault() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: number) => api.post<{ vault: Vault }>(`/vaults/${id}/restore`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['vaults'] }),
  })
}

export function usePurgeVault() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: number) => api.post<{ purged: boolean }>(`/vaults/${id}/purge`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['vaults'] }),
  })
}

export function useUpdateVault() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, ...attrs }: { id: number; name?: string; description?: string; is_default?: boolean }) =>
      api.patch<{ vault: Vault }>(`/vaults/${id}`, attrs),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['vaults'] }),
  })
}

export function useCreateVault() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (attrs: { name: string; description?: string }) =>
      api.post<{ vault: Vault }>('/vaults', attrs),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['vaults'] })
      // Backend records `first_vault_created` in Vaults.create_vault/2;
      // refresh /status so the onboarding checklist ticks immediately.
      qc.invalidateQueries({ queryKey: ['onboarding', 'status'] })
    },
  })
}
