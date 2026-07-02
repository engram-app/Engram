import { getActiveVaultId } from "./active-vault";
import { getApiBase, joinApiUrl } from "./base";
import { getDeviceId } from "./device-id";

// Module-level token getter — set by AuthTokenProvider component
let tokenGetter: (() => Promise<string | null>) | null = null;

// Module-level upgrade handler — the UpgradeDialogProvider registers itself
// on mount so the client (a plain module, no React) can fire the dialog when
// the backend returns a 402 limit_exceeded. Kept as a setter (Option B) rather
// than an event bus to stay simple and tree-shakeable.
let upgradeHandler: ((reason: string) => void) | null = null;

async function authFetch(path: string, options: RequestInit = {}): Promise<Response> {
	const token = tokenGetter ? await tokenGetter() : null;

	const headers = new Headers(options.headers);
	headers.set("Content-Type", "application/json");
	if (token) {
		headers.set("Authorization", `Bearer ${token}`);
	}
	const vaultId = getActiveVaultId();
	if (vaultId != null) {
		headers.set("X-Vault-ID", String(vaultId));
	}
	headers.set("X-Device-Id", getDeviceId());

	// joinApiUrl handles both same-origin (selfhost) and cross-origin
	// (saas, `https://api.engram.page`). For selfhost apiBase is "" so
	// this composes to `/api${path}` identically to the pre-eject shape.
	const url = joinApiUrl(getApiBase(), `/api${path}`);
	const response = await fetch(url, { ...options, headers });

	if (!response.ok) {
		const body = await response.json().catch(() => ({}));
		if (response.status === 402) {
			const reason = body.reason ?? "unknown";
			if (upgradeHandler) {
				upgradeHandler(reason);
			}
			throw new LimitExceededError(
				reason,
				body.limit_key ?? null,
				body.limit ?? null,
				body.current ?? null,
				body.upgrade_url ?? null,
			);
		}
		throw new ApiError(response.status, body.error ?? response.statusText);
	}

	return response;
}

export function setTokenGetter(getter: () => Promise<string | null>) {
	tokenGetter = getter;
}

export function setUpgradeHandler(fn: ((reason: string) => void) | null) {
	upgradeHandler = fn;
}

export class ApiError extends Error {
	constructor(
		public status: number,
		message: string,
	) {
		super(message);
		this.name = "ApiError";
	}
}

export class LimitExceededError extends Error {
	readonly name = "LimitExceededError";
	constructor(
		public readonly reason: string,
		public readonly limitKey: string | null,
		public readonly limit: number | boolean | null,
		public readonly current: number | null,
		public readonly upgradeUrl: string | null,
	) {
		super(`Engram limit: ${reason}`);
	}
}

export const api = {
	async get<T>(path: string): Promise<T> {
		const res = await authFetch(path);
		return res.json();
	},

	async post<T>(
		path: string,
		body?: unknown,
		opts?: { headers?: Record<string, string>; signal?: AbortSignal },
	): Promise<T> {
		const res = await authFetch(path, {
			method: "POST",
			body: body ? JSON.stringify(body) : undefined,
			headers: opts?.headers,
			signal: opts?.signal,
		});
		return res.json();
	},

	async patch<T>(path: string, body?: unknown): Promise<T> {
		const res = await authFetch(path, {
			method: "PATCH",
			body: body ? JSON.stringify(body) : undefined,
		});
		return res.json();
	},

	async del<T>(path: string): Promise<T> {
		const res = await authFetch(path, { method: "DELETE" });
		// 204 No Content is the conventional REST response for DELETE; tolerate
		// empty bodies so callers don't have to differentiate.
		if (res.status === 204 || res.headers.get("content-length") === "0") {
			return undefined as T;
		}
		return res.json();
	},

	async getBlob(path: string): Promise<Blob> {
		const res = await authFetch(path);
		return res.blob();
	},
};
