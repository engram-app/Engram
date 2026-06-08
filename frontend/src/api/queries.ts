import { type QueryClient, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
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
  id: number
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
  // null for orphan path hits (Task 1 backend) — frontend should treat
  // these as non-clickable since there's no id-routable target.
  id: number | null
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
          .map((n, i) => ({
            // Demo notes have string ids; synthesize negative numeric ids
            // so they don't collide with real backend ids and so the
            // NoteSummary contract is satisfied (id: number).
            id: -(i + 1),
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

export function useNote(id: number | null) {
  const vaultId = useActiveVaultId()
  return useQuery({
    queryKey: ['note', vaultId, id],
    queryFn: () => api.get<Note>(`/notes/by-id/${id}`),
    enabled: id != null,
  })
}

// Legacy path-keyed resolver. Task 6 wires this up behind the
// `/note/*` catch-all so old links keep working: it fetches by path,
// pulls the `id`, and replaces the URL with `/note/by-id/:id`.
export function useNoteByPath(path: string) {
  const vaultId = useActiveVaultId()
  return useQuery({
    queryKey: ['noteByPath', vaultId, path],
    queryFn: () => api.get<Note>(`/notes/${encodePathSegments(path)}`),
    enabled: path.length > 0,
  })
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

// Inline billing mutations replacing the portal redirect — each invalidates
// /billing/status + /billing/subscription so the StatusCard reflects the
// new scheduled change immediately, before webhook sync catches up.

function invalidateBilling(qc: QueryClient) {
  qc.invalidateQueries({ queryKey: ['billing', 'status'] })
  qc.invalidateQueries({ queryKey: ['billing', 'subscription'] })
}

export function useCancelSubscription() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: () => api.post<Record<string, unknown>>('/billing/cancel-subscription'),
    onSuccess: () => invalidateBilling(qc),
  })
}

export function useReverseCancel() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: () => api.post<Record<string, unknown>>('/billing/reverse-cancel'),
    onSuccess: () => invalidateBilling(qc),
  })
}

export interface PlanChangePreview {
  old_total: number
  new_total: number
  immediate_charge_or_credit: number
  next_billed_at: string
}

export function usePlanChangePreview(targetPriceId: string | null) {
  return useQuery({
    queryKey: ['billing', 'plan-change', 'preview', targetPriceId],
    enabled: targetPriceId !== null,
    queryFn: () =>
      api.post<PlanChangePreview>('/billing/plan-change/preview', {
        target_price_id: targetPriceId,
      }),
    // Preview hits Paddle. Without these, every window focus/refocus
    // (alt-tab back to the picker tab) re-POSTs to Paddle. The data
    // is stable for the lifetime of the picker session — proration
    // math only changes when the user picks a different target or
    // a webhook flips their subscription (both invalidate the key).
    staleTime: 5 * 60_000,
    refetchOnWindowFocus: false,
  })
}

export function useConfirmPlanChange() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (targetPriceId: string) =>
      api.post<Record<string, unknown>>('/billing/plan-change/confirm', {
        target_price_id: targetPriceId,
      }),
    onSuccess: () => invalidateBilling(qc),
  })
}

// ── Tree mutations (rename / delete / duplicate) ─────────────
//
// Folder/note rename + delete on the tree. Rename endpoints return 409
// on target-exists (collision) and 404 if the source is missing — both
// surface as ApiError to the caller via api.post / api.del.
//
// Each mutation runs optimistically: `onMutate` snapshots the affected
// caches, applies the change locally so the UI updates synchronously,
// and stashes the snapshot in the mutation context. `onError` restores
// the snapshot and toasts the failure. `onSettled` invalidates the
// affected query families so the server stays the source of truth and
// out-of-band changes (Phoenix channel push, other-tab edits) get
// reconciled.

// Path → parent folder. `'a/b/c.md'` → `'a/b'`; `'a.md'` → `''`. Same
// rule the backend uses when computing `folder` on a NoteSummary.
function folderOf(path: string): string {
  const slash = path.lastIndexOf('/')
  return slash < 0 ? '' : path.slice(0, slash)
}

// Apply `mut` to the entry at `key` only if it is currently cached.
// Skipping uncached keys keeps optimistic edits cheap and avoids
// pre-seeding caches that would otherwise refetch lazily on mount.
function updateCachedList<T>(
  qc: QueryClient,
  key: readonly unknown[],
  mut: (data: { notes: T[] }) => { notes: T[] },
) {
  const prev = qc.getQueryData<{ notes: T[] }>(key as readonly unknown[])
  if (!prev) return
  qc.setQueryData(key as readonly unknown[], mut(prev))
}

// 409/404/etc → human-grade toast copy. Centralised so all four
// mutations (and the standalone drop handler) speak the same dialect.
function renameErrorToast(err: ApiError, kind: 'file' | 'folder') {
  const noun = kind === 'file' ? 'note' : 'folder'
  if (err.status === 409) toast.error(`A ${noun} with that name already exists.`)
  else if (err.status === 404) toast.error(`${noun[0]?.toUpperCase()}${noun.slice(1)} no longer exists.`)
  else toast.error('Rename failed.')
}

function deleteErrorToast(err: ApiError, kind: 'file' | 'folder') {
  const noun = kind === 'file' ? 'Note' : 'Folder'
  if (err.status === 404) toast.error(`${noun} no longer exists.`)
  else toast.error('Delete failed.')
}

interface RenameNoteContext {
  oldFolder: string
  newFolder: string
  oldFolderNotes: { notes: NoteSummary[] } | undefined
  newFolderNotes: { notes: NoteSummary[] } | undefined
  folders: { folders: Folder[] } | undefined
  oldNote: Note | undefined
}

export function useRenameNote() {
  const qc = useQueryClient()
  const vaultId = useActiveVaultId()
  return useMutation<
    { renamed: boolean; old_path: string; new_path: string; note: Note },
    ApiError,
    { old_path: string; new_path: string },
    RenameNoteContext
  >({
    mutationFn: (vars) =>
      api.post<{ renamed: boolean; old_path: string; new_path: string; note: Note }>(
        '/notes/rename',
        vars,
      ),
    onMutate: async ({ old_path, new_path }) => {
      const oldFolder = folderOf(old_path)
      const newFolder = folderOf(new_path)
      const oldListKey = ['folderNotes', vaultId, oldFolder] as const
      const newListKey = ['folderNotes', vaultId, newFolder] as const
      const foldersKey = ['folders', vaultId] as const
      const oldNoteKey = ['note', vaultId, old_path] as const
      const newNoteKey = ['note', vaultId, new_path] as const

      // Stop in-flight queries from clobbering the optimistic write.
      await qc.cancelQueries({ queryKey: ['folderNotes', vaultId] })
      await qc.cancelQueries({ queryKey: foldersKey })
      await qc.cancelQueries({ queryKey: oldNoteKey })

      const ctx: RenameNoteContext = {
        oldFolder,
        newFolder,
        oldFolderNotes: qc.getQueryData<{ notes: NoteSummary[] }>(oldListKey),
        newFolderNotes: qc.getQueryData<{ notes: NoteSummary[] }>(newListKey),
        folders: qc.getQueryData<{ folders: Folder[] }>(foldersKey),
        oldNote: qc.getQueryData<Note>(oldNoteKey),
      }

      // Pull the note out of the old folder list.
      const moved =
        ctx.oldFolderNotes?.notes.find((n) => n.path === old_path) ??
        // If the old list isn't cached, synthesize a stub from the note
        // body so we still have something to drop into the new folder.
        (ctx.oldNote
          ? ({
              id: ctx.oldNote.id,
              path: ctx.oldNote.path,
              title: ctx.oldNote.title,
              folder: ctx.oldNote.folder,
              tags: ctx.oldNote.tags,
              version: ctx.oldNote.version,
              mtime: ctx.oldNote.mtime,
              created_at: ctx.oldNote.created_at,
              updated_at: ctx.oldNote.updated_at,
            } satisfies NoteSummary)
          : null)

      if (ctx.oldFolderNotes) {
        updateCachedList<NoteSummary>(qc, oldListKey, (prev) => ({
          notes: prev.notes.filter((n) => n.path !== old_path),
        }))
      }

      // Drop a renamed copy into the new folder list (if cached).
      if (moved) {
        const renamed: NoteSummary = { ...moved, path: new_path, folder: newFolder }
        if (ctx.newFolderNotes) {
          updateCachedList<NoteSummary>(qc, newListKey, (prev) => ({
            notes: [...prev.notes.filter((n) => n.path !== new_path), renamed],
          }))
        }
      }

      // Adjust folder counts when the note crosses folder boundaries.
      if (oldFolder !== newFolder && ctx.folders) {
        qc.setQueryData<{ folders: Folder[] }>(foldersKey, (prev) => {
          if (!prev) return prev
          let next = prev.folders
            .map((f) => (f.name === oldFolder ? { ...f, count: Math.max(0, f.count - 1) } : f))
          const hasNewEntry = next.some((f) => f.name === newFolder)
          if (hasNewEntry) {
            next = next.map((f) =>
              f.name === newFolder ? { ...f, count: f.count + 1 } : f,
            )
          } else if (newFolder !== '') {
            next = [...next, { name: newFolder, count: 1 }]
          } else {
            // Root files don't get a synthetic '' entry — folders() filters
            // those out anyway; the note shows up via RootFiles.
          }
          return { folders: next }
        })
      }

      // Move the note body cache from old to new path.
      if (ctx.oldNote) {
        qc.setQueryData<Note>(newNoteKey, { ...ctx.oldNote, path: new_path, folder: newFolder })
        qc.removeQueries({ queryKey: oldNoteKey })
      }

      return ctx
    },
    onError: (err, _vars, ctx) => {
      if (!ctx) return
      const oldListKey = ['folderNotes', vaultId, ctx.oldFolder]
      const newListKey = ['folderNotes', vaultId, ctx.newFolder]
      const foldersKey = ['folders', vaultId]
      const oldNoteKey = ['note', vaultId, _vars.old_path]
      const newNoteKey = ['note', vaultId, _vars.new_path]
      if (ctx.oldFolderNotes !== undefined) qc.setQueryData(oldListKey, ctx.oldFolderNotes)
      if (ctx.newFolderNotes !== undefined) qc.setQueryData(newListKey, ctx.newFolderNotes)
      if (ctx.folders !== undefined) qc.setQueryData(foldersKey, ctx.folders)
      if (ctx.oldNote !== undefined) qc.setQueryData(oldNoteKey, ctx.oldNote)
      qc.removeQueries({ queryKey: newNoteKey })
      renameErrorToast(err, 'file')
    },
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ['folders', vaultId] })
      qc.invalidateQueries({ queryKey: ['folderNotes', vaultId] })
      qc.invalidateQueries({ queryKey: ['note', vaultId] })
    },
  })
}

interface RenameFolderContext {
  folders: { folders: Folder[] } | undefined
  // Snapshot of every cached folderNotes entry we touched, keyed by the
  // joined query key. Folder rename is coarse (see below) — we DROP all
  // child folderNotes entries to force refetch on next expand, which
  // means rollback needs to restore them.
  childLists: Array<{ key: readonly unknown[]; data: { notes: NoteSummary[] } | undefined }>
}

export function useRenameFolder() {
  const qc = useQueryClient()
  const vaultId = useActiveVaultId()
  return useMutation<
    { renamed: boolean; old_path: string; new_path: string; count: number },
    ApiError,
    { old_path: string; new_path: string },
    RenameFolderContext
  >({
    mutationFn: (vars) =>
      api.post<{
        renamed: boolean
        old_path: string
        new_path: string
        count: number
      }>('/folders/rename', vars),
    onMutate: async ({ old_path, new_path }) => {
      // COARSE optimistic strategy: rewrite folder names in ['folders']
      // (the renamed folder + every descendant) and DROP every cached
      // folderNotes entry under the old prefix. Note paths inside those
      // lists would need full prefix-rewrite to stay coherent, and the
      // user almost certainly isn't looking at every descendant list at
      // once — refetching on next expand is cheap and exact. The list
      // for the renamed folder ITSELF gets the same treatment.
      const foldersKey = ['folders', vaultId] as const
      await qc.cancelQueries({ queryKey: ['folderNotes', vaultId] })
      await qc.cancelQueries({ queryKey: foldersKey })

      const ctx: RenameFolderContext = {
        folders: qc.getQueryData<{ folders: Folder[] }>(foldersKey),
        childLists: [],
      }

      // Rewrite folder names.
      if (ctx.folders) {
        qc.setQueryData<{ folders: Folder[] }>(foldersKey, (prev) => {
          if (!prev) return prev
          const oldPrefix = `${old_path}/`
          return {
            folders: prev.folders.map((f) => {
              if (f.name === old_path) return { ...f, name: new_path }
              if (f.name.startsWith(oldPrefix)) {
                return { ...f, name: `${new_path}/${f.name.slice(oldPrefix.length)}` }
              }
              return f
            }),
          }
        })
      }

      // Snapshot + drop every cached folderNotes entry under the old prefix.
      const all = qc.getQueryCache().findAll({ queryKey: ['folderNotes', vaultId] })
      for (const q of all) {
        const folder = q.queryKey[2] as string | undefined
        if (typeof folder !== 'string') continue
        if (folder !== old_path && !folder.startsWith(`${old_path}/`)) continue
        ctx.childLists.push({
          key: q.queryKey,
          data: qc.getQueryData<{ notes: NoteSummary[] }>(q.queryKey),
        })
        qc.removeQueries({ queryKey: q.queryKey })
      }

      return ctx
    },
    onError: (err, _vars, ctx) => {
      if (!ctx) return
      if (ctx.folders !== undefined) qc.setQueryData(['folders', vaultId], ctx.folders)
      for (const entry of ctx.childLists) {
        if (entry.data !== undefined) qc.setQueryData(entry.key, entry.data)
      }
      renameErrorToast(err, 'folder')
    },
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ['folders', vaultId] })
      qc.invalidateQueries({ queryKey: ['folderNotes', vaultId] })
    },
  })
}

interface DeleteNoteContext {
  folder: string
  id: number
  folderNotes: { notes: NoteSummary[] } | undefined
  folders: { folders: Folder[] } | undefined
  note: Note | undefined
}

// `path` rides along so optimistic onMutate can locate the row in the
// folderNotes cache + adjust the parent folder's count without a round
// trip. The URL itself only needs the id.
export function useDeleteNote() {
  const qc = useQueryClient()
  const vaultId = useActiveVaultId()
  return useMutation<
    { deleted: boolean } | void,
    ApiError,
    { id: number; path: string },
    DeleteNoteContext
  >({
    mutationFn: ({ id }) => api.del<{ deleted: boolean }>(`/notes/by-id/${id}`),
    onMutate: async ({ id, path }) => {
      const folder = folderOf(path)
      const listKey = ['folderNotes', vaultId, folder] as const
      const foldersKey = ['folders', vaultId] as const
      const noteKey = ['note', vaultId, id] as const

      await qc.cancelQueries({ queryKey: ['folderNotes', vaultId] })
      await qc.cancelQueries({ queryKey: foldersKey })
      await qc.cancelQueries({ queryKey: noteKey })

      const ctx: DeleteNoteContext = {
        folder,
        id,
        folderNotes: qc.getQueryData<{ notes: NoteSummary[] }>(listKey),
        folders: qc.getQueryData<{ folders: Folder[] }>(foldersKey),
        note: qc.getQueryData<Note>(noteKey),
      }

      if (ctx.folderNotes) {
        updateCachedList<NoteSummary>(qc, listKey, (prev) => ({
          notes: prev.notes.filter((n) => n.id !== id),
        }))
      }
      if (ctx.folders) {
        qc.setQueryData<{ folders: Folder[] }>(foldersKey, (prev) =>
          prev
            ? {
                folders: prev.folders.map((f) =>
                  f.name === folder ? { ...f, count: Math.max(0, f.count - 1) } : f,
                ),
              }
            : prev,
        )
      }
      qc.removeQueries({ queryKey: noteKey })
      return ctx
    },
    onError: (err, _vars, ctx) => {
      if (!ctx) return
      const listKey = ['folderNotes', vaultId, ctx.folder]
      const foldersKey = ['folders', vaultId]
      const noteKey = ['note', vaultId, ctx.id]
      if (ctx.folderNotes !== undefined) qc.setQueryData(listKey, ctx.folderNotes)
      if (ctx.folders !== undefined) qc.setQueryData(foldersKey, ctx.folders)
      if (ctx.note !== undefined) qc.setQueryData(noteKey, ctx.note)
      deleteErrorToast(err, 'file')
    },
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ['folders', vaultId] })
      qc.invalidateQueries({ queryKey: ['folderNotes', vaultId] })
    },
  })
}

interface DeleteFolderContext {
  folders: { folders: Folder[] } | undefined
  folderList: { notes: NoteSummary[] } | undefined
}

export function useDeleteFolder() {
  const qc = useQueryClient()
  const vaultId = useActiveVaultId()
  return useMutation<
    { deleted: boolean } | void,
    ApiError,
    { path: string },
    DeleteFolderContext
  >({
    mutationFn: ({ path }) =>
      api.del<{ deleted: boolean }>(`/folders/${encodePathSegments(path)}`),
    onMutate: async ({ path }) => {
      // Coarse: drop the folder entry + its own folderNotes cache. We
      // don't chase descendant folderNotes entries — the user will
      // refetch them next time they expand the (now nonexistent) child.
      const foldersKey = ['folders', vaultId] as const
      const listKey = ['folderNotes', vaultId, path] as const

      await qc.cancelQueries({ queryKey: foldersKey })
      await qc.cancelQueries({ queryKey: listKey })

      const ctx: DeleteFolderContext = {
        folders: qc.getQueryData<{ folders: Folder[] }>(foldersKey),
        folderList: qc.getQueryData<{ notes: NoteSummary[] }>(listKey),
      }

      if (ctx.folders) {
        qc.setQueryData<{ folders: Folder[] }>(foldersKey, (prev) =>
          prev
            ? {
                folders: prev.folders.filter(
                  (f) => f.name !== path && !f.name.startsWith(`${path}/`),
                ),
              }
            : prev,
        )
      }
      qc.removeQueries({ queryKey: listKey })
      return ctx
    },
    onError: (err, vars, ctx) => {
      if (!ctx) return
      if (ctx.folders !== undefined) qc.setQueryData(['folders', vaultId], ctx.folders)
      if (ctx.folderList !== undefined)
        qc.setQueryData(['folderNotes', vaultId, vars.path], ctx.folderList)
      deleteErrorToast(err, 'folder')
    },
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ['folders', vaultId] })
      qc.invalidateQueries({ queryKey: ['folderNotes', vaultId] })
    },
  })
}

// Duplicate a note: read source content, then write a fresh note at a
// caller-chosen `new_path`. The collision-free name is computed by the
// caller (see `viewer/tree-actions/duplicate.ts#nextCopyName`) — keeping
// this mutation a thin GET-then-POST means tests don't need to reason
// about siblings, and the name policy stays in one place.
//
// Optimistic strategy: drop a placeholder NoteSummary into the new
// folder's list immediately so the row appears in the tree. The GET+POST
// happens in the background; on success the placeholder is replaced
// (via onSettled refetch); on error the placeholder is pulled.

interface DuplicateNoteContext {
  newFolder: string
  newFolderNotes: { notes: NoteSummary[] } | undefined
}

export function useDuplicateNote() {
  const qc = useQueryClient()
  const vaultId = useActiveVaultId()
  return useMutation<
    { note: Note },
    ApiError,
    { src_path: string; new_path: string },
    DuplicateNoteContext
  >({
    mutationFn: async ({ src_path, new_path }) => {
      const src = await api.get<Note>(`/notes/${encodePathSegments(src_path)}`)
      return api.post<{ note: Note }>('/notes', {
        path: new_path,
        content: src.content ?? '',
        mtime: Date.now() / 1000,
      })
    },
    onMutate: async ({ src_path, new_path }) => {
      const newFolder = folderOf(new_path)
      const listKey = ['folderNotes', vaultId, newFolder] as const
      await qc.cancelQueries({ queryKey: listKey })

      const ctx: DuplicateNoteContext = {
        newFolder,
        newFolderNotes: qc.getQueryData<{ notes: NoteSummary[] }>(listKey),
      }

      // Seed metadata from the source row if we have it cached — gives
      // the placeholder a usable title/tags so the row looks real.
      const srcRowFromOldList = qc
        .getQueryData<{ notes: NoteSummary[] }>(['folderNotes', vaultId, folderOf(src_path)])
        ?.notes.find((n) => n.path === src_path)
      const now = new Date().toISOString()
      const placeholder: NoteSummary = {
        // Placeholder id — the real one arrives with the POST response.
        // Negative to avoid collisions with real backend ids; onSettled
        // refetches the folder list so this gets replaced.
        id: -Date.now(),
        path: new_path,
        title: srcRowFromOldList?.title ?? '',
        folder: newFolder,
        tags: srcRowFromOldList?.tags ?? [],
        version: 1,
        mtime: now,
        created_at: now,
        updated_at: now,
      }

      if (ctx.newFolderNotes) {
        updateCachedList<NoteSummary>(qc, listKey, (prev) => ({
          notes: [...prev.notes.filter((n) => n.path !== new_path), placeholder],
        }))
      }
      return ctx
    },
    onError: (err, _vars, ctx) => {
      if (ctx?.newFolderNotes !== undefined) {
        qc.setQueryData(['folderNotes', vaultId, ctx.newFolder], ctx.newFolderNotes)
      }
      if (err.status === 409) {
        toast.error('A note with that name already exists.')
      } else {
        toast.error('Failed to duplicate.')
      }
    },
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ['folders', vaultId] })
      qc.invalidateQueries({ queryKey: ['folderNotes', vaultId] })
    },
  })
}
