import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { api } from './client'
import { useActiveVaultId } from './active-vault'

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
}

// Query hooks

export function useFolders() {
  const vaultId = useActiveVaultId()
  return useQuery({
    queryKey: ['folders', vaultId],
    queryFn: () => api.get<{ folders: Folder[] }>('/folders'),
    select: (data) => data.folders,
  })
}

export function useFolderNotes(folder: string, options?: { enabled?: boolean }) {
  const vaultId = useActiveVaultId()
  return useQuery({
    queryKey: ['folderNotes', vaultId, folder],
    queryFn: () =>
      api.get<{ notes: NoteSummary[] }>(`/folders/list?folder=${encodeURIComponent(folder)}`),
    select: (data) => data.notes,
    enabled: options?.enabled ?? folder.length > 0,
  })
}

export function useNote(path: string) {
  const vaultId = useActiveVaultId()
  return useQuery({
    queryKey: ['note', vaultId, path],
    queryFn: () => api.get<Note>(`/notes/${encodePathSegments(path)}`),
    enabled: !!path,
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
    starter: string
    pro: string
  }
  customer_email: string
  custom_data: {
    user_id: number
  }
  // Maximum number of active vaults the user may have, or null for unlimited.
  vaults_cap: number | null
}

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

export interface OnboardingStatus {
  enabled: boolean
  terms_ok?: boolean
  subscription_ok?: boolean
  current_tos_version?: string
  current_privacy_version?: string
  next_step: 'agreement' | 'billing' | 'done'
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

export function useAcceptTerms() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (body: {
      tos_version: string
      tos_hash: string
      privacy_version: string
      privacy_hash: string
    }) => api.post<{ version: string; accepted_at: string }>('/onboarding/accept-terms', body),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['onboarding', 'status'] })
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
}

export interface EncryptionProgress {
  processed: number
  total: number
  status: EncryptionStatus
  started_at: string | null
}

// Vault hooks

export function useVaults() {
  return useQuery({
    queryKey: ['vaults'],
    queryFn: () => api.get<{ vaults: Vault[] }>('/vaults'),
    select: (data) => data.vaults,
  })
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
    onSuccess: () => qc.invalidateQueries({ queryKey: ['vaults'] }),
  })
}
