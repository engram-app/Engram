import { getActiveVaultId } from './active-vault'

// Module-level token getter — set by AuthTokenProvider component
let tokenGetter: (() => Promise<string | null>) | null = null

export function setTokenGetter(getter: () => Promise<string | null>) {
  tokenGetter = getter
}

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message)
    this.name = 'ApiError'
  }
}

async function authFetch(path: string, options: RequestInit = {}): Promise<Response> {
  const token = tokenGetter ? await tokenGetter() : null

  const headers = new Headers(options.headers)
  headers.set('Content-Type', 'application/json')
  if (token) {
    headers.set('Authorization', `Bearer ${token}`)
  }
  const vaultId = getActiveVaultId()
  if (vaultId != null) {
    headers.set('X-Vault-ID', String(vaultId))
  }

  const response = await fetch(`/api${path}`, { ...options, headers })

  if (!response.ok) {
    const body = await response.json().catch(() => ({}))
    throw new ApiError(response.status, body.error ?? response.statusText)
  }

  return response
}

export const api = {
  async get<T>(path: string): Promise<T> {
    const res = await authFetch(path)
    return res.json()
  },

  async post<T>(path: string, body?: unknown): Promise<T> {
    const res = await authFetch(path, {
      method: 'POST',
      body: body ? JSON.stringify(body) : undefined,
    })
    return res.json()
  },

  async del<T>(path: string): Promise<T> {
    const res = await authFetch(path, { method: 'DELETE' })
    return res.json()
  },
}
