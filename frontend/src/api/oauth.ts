import { api } from './client'

export interface OAuthClientMetadata {
  client_id: string
  client_name: string
}

export interface OAuthConsentParams {
  client_id: string
  redirect_uri: string
  response_type: string
  code_challenge: string
  code_challenge_method: string
  state: string
  scope: string
  resource?: string
  vault_choice: string
}

export interface OAuthConsentResponse {
  redirect_uri: string
}

export async function fetchOAuthClient(clientId: string): Promise<OAuthClientMetadata> {
  return fetch(`/api/oauth/clients/${encodeURIComponent(clientId)}`).then(async (res) => {
    if (!res.ok) {
      throw new Error(`oauth client lookup failed: ${res.status}`)
    }
    return res.json()
  })
}

export async function postOAuthConsent(
  params: OAuthConsentParams,
): Promise<OAuthConsentResponse> {
  return api.post<OAuthConsentResponse>('/oauth/authorize/consent', params)
}
