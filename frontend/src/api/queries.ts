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
  tier: 'none' | 'trial' | 'starter' | 'pro'
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
}

export function useBillingConfig() {
  return useQuery({
    queryKey: ['billing', 'config'],
    queryFn: () => api.get<BillingConfig>('/billing/config'),
    staleTime: Infinity,
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
