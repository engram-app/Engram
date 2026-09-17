import { getApiBase, joinApiUrl } from "./base";
import { api } from "./client";

export interface OAuthClientMetadata {
	client_id: string;
	client_name: string;
	// "mcp" | "obsidian" — drives the proactive cap UI on /oauth/consent.
	// DCR rejects "obsidian"; device-flow clients carry that kind. The
	// backend `oauth_clients_controller.show/2` echoes it from the DB row.
	kind: "mcp" | "obsidian";
	// Catalog slug for the connecting client ("antigravity", "claude_code", …),
	// or null when it cannot be attributed. Resolved server-side from the
	// redirect the grant is using; the consent page passes it to the wizard so
	// the FTUX tool question isn't asked of someone who just answered it by
	// connecting a tool.
	slug: string | null;
}

export interface OAuthConsentParams {
	client_id: string;
	redirect_uri: string;
	response_type: string;
	code_challenge: string;
	code_challenge_method: string;
	state: string;
	scope: string;
	resource?: string;
	// Absent = all vaults, including ones created later. A non-empty array =
	// exactly those vaults. Never send an empty array — the backend rejects it
	// rather than widening it to "all".
	vault_ids?: string[];
	// The user's own name for this connection. Omitted entirely when they left
	// the input at its prefilled placeholder — a default nobody typed must not
	// be stored as if they chose it. Over 120 chars is REJECTED by the backend
	// (access_denied), not truncated.
	label?: string;
}

export interface OAuthConsentResponse {
	redirect_uri: string;
}

// `redirectUri` is the one THIS request is using, not the registered list.
// The backend resolves the client's catalog slug from it and ignores any value
// the client never registered, so passing it widens nothing.
export function fetchOAuthClient(
	clientId: string,
	redirectUri?: string,
): Promise<OAuthClientMetadata> {
	const query = redirectUri ? `?redirect_uri=${encodeURIComponent(redirectUri)}` : "";
	const url = joinApiUrl(
		getApiBase(),
		`/api/oauth/clients/${encodeURIComponent(clientId)}${query}`,
	);
	return fetch(url).then((res) => {
		if (!res.ok) {
			throw new Error(`oauth client lookup failed: ${res.status}`);
		}
		return res.json();
	});
}

export function postOAuthConsent(params: OAuthConsentParams): Promise<OAuthConsentResponse> {
	return api.post<OAuthConsentResponse>("/oauth/authorize/consent", params);
}
