import { track } from "../analytics/track";
import { rlog } from "../observability/remote-log";
import { newTraceContext, tracingEnabled } from "../observability/trace";
import { scrubUrl } from "../sentry";
import { getActiveVaultId } from "./active-vault";
import { getApiBase, joinApiUrl } from "./base";
import { getDeviceId } from "./device-id";
import { type NetworkContext, networkContext } from "./network-context";

// Module-level token getter — set by AuthTokenProvider component
let tokenGetter: (() => Promise<string | null>) | null = null;

// Module-level upgrade handler — the UpgradeDialogProvider registers itself
// on mount so the client (a plain module, no React) can fire the dialog when
// the backend returns a 402 limit_exceeded. Kept as a setter (Option B) rather
// than an event bus to stay simple and tree-shakeable.
let upgradeHandler: ((reason: string) => void) | null = null;

/** First "field: message" from the unified 422 shape %{errors: %{field => [msgs]}}.
 *  Controllers return this shape with no top-level `error` key, so the generic
 *  error surface must read it or validation toasts degrade to bare statusText. */
function firstValidationError(errors: unknown): string | undefined {
	if (typeof errors !== "object" || errors === null) {
		return;
	}
	const [field, msgs] = Object.entries(errors)[0] ?? [];
	if (!field) {
		return;
	}
	const msg = Array.isArray(msgs) ? msgs[0] : msgs;
	return typeof msg === "string" ? `${field}: ${msg}` : field;
}

/** Report a request that failed in a way that means "broken", not "no": a
 *  network or CORS failure, or a 5xx. Reported from here because every caller
 *  HANDLES its errors (a mutation's onError toasts and stops), so nothing else
 *  ever sees them. A CORS-blocked /folders/batch-delete broke folder delete in
 *  prod with nothing reported anywhere.
 *
 *  Goes to the backend log pipe (Loki, `platform=web`, `[client:api_request]`)
 *  where the Grafana alert reads it. The URL is scrubbed: note paths travel in
 *  URLs, so only the route shape is kept.
 *
 *  ponytail: prod keeps the resource (`/folders/:seg`), not the endpoint.
 *  Report the caller's route template if per-endpoint alerts are ever needed. */
function reportFailure({ kind, method, url, context }: Failure) {
	// Spread: an interface has no index signature, a plain object type does.
	rlog().error("api_request", `${kind} ${method} ${scrubUrl(url)}`, context && { ...context });
}

/** navigator.onLine stays true through a laptop wake or a dead Wi-Fi, so a
 *  failed fetch alone cannot tell "offline" from "this route is broken". Probe
 *  the API host: if it answers, the network is fine and the failure is ours
 *  (CORS, a bad route). `no-cors` so the probe itself can never be CORS-blocked. */
let inFlightProbe: Promise<boolean> | null = null;

/** One probe answers for every failure in flight: a wake fails them all at once. */
function probeApi(): Promise<boolean> {
	inFlightProbe ??= fetch(joinApiUrl(getApiBase(), "/api/health"), {
		mode: "no-cors",
		cache: "no-store",
	})
		.then(
			() => true,
			() => false,
		)
		.finally(() => {
			inFlightProbe = null;
		});
	return inFlightProbe;
}

/** A network failure (it has context) reports only if the API is reachable. */
async function sendReport(failure: Failure) {
	if (!failure.context || (await probeApi())) {
		reportFailure(failure);
	}
}

interface Failure {
	kind: string;
	method: string;
	url: string;
	context?: NetworkContext;
}

/** Reports waiting on whether the caller will retry, keyed by the thrown error.
 *  React Query retries a failed query, and a retry that succeeds is invisible to
 *  the user: 2026-10-20 one user's five boot GETs failed once, all succeeded a
 *  second later, and the per-attempt report paged anyway. */
const pendingReports = new WeakMap<object, Failure>();

/** Report `err` once the current attempt has settled, unless a retry claims it.
 *  React Query decides to retry inside the rejection's microtasks; a timer runs
 *  after them. A caller outside React Query never claims, so it still reports. */
function reportUnlessRetried(err: object, failure: Failure) {
	pendingReports.set(err, failure);
	setTimeout(() => {
		const pending = pendingReports.get(err);
		pendingReports.delete(err);
		if (pending) {
			sendReport(pending);
		}
	}, 0);
}

/** Methods safe to send twice, so a network error gets one more try here.
 *  Not GET: React Query already retries queries. Not POST/PATCH: not
 *  idempotent. Every DELETE route was checked for a safe repeat (see api.del). */
const RETRY_ONCE_METHODS = new Set(["PUT", "DELETE"]);
const RETRY_DELAY_MS = 300;

async function authFetch(
	path: string,
	options: RequestInit = {},
	{ retryNetworkError = true } = {},
): Promise<Response> {
	const token = await getAuthToken();

	const headers = new Headers(options.headers);
	headers.set("Content-Type", "application/json");
	if (token) {
		headers.set("Authorization", `Bearer ${token}`);
	}
	const vaultId = getActiveVaultId();
	if (vaultId !== null) {
		headers.set("X-Vault-ID", String(vaultId));
	}
	headers.set("X-Device-Id", getDeviceId());
	// Distributed trace leg A: gated on the real `tracingEnabled` config
	// field (default false). Disabled = a single boolean check, no id
	// generation, no header. The render-leg beacon lives in channel.ts.
	if (tracingEnabled()) {
		headers.set("traceparent", newTraceContext().traceparent);
	}

	// joinApiUrl handles both same-origin (selfhost) and cross-origin
	// (saas, `https://api.engram.page`). For selfhost apiBase is "" so
	// this composes to `/api${path}` identically to the pre-eject shape.
	const url = joinApiUrl(getApiBase(), `/api${path}`);
	const method = options.method ?? "GET";
	const retriesOnce = retryNetworkError && RETRY_ONCE_METHODS.has(method);
	const attemptFetch = async (
		tryNumber: number,
	): Promise<{ response: Response; attempt: number }> => {
		const startedAt = performance.now();
		try {
			return { response: await fetch(url, { ...options, headers }), attempt: tryNumber };
		} catch (err) {
			// A TypeError is the browser's network failure; an AbortError (a
			// DOMException) is the caller's choice and is never retried.
			if (retriesOnce && tryNumber === 1 && err instanceof TypeError) {
				await new Promise((resolve) => setTimeout(resolve, RETRY_DELAY_MS));
				return attemptFetch(2);
			}
			// Aborts are the caller's choice and offline is the user's network, not
			// ours. Everything else (CORS, DNS, TLS, connection reset) is a TypeError
			// the browser deliberately leaves vague.
			const aborted = err instanceof Error && err.name === "AbortError";
			if (!aborted && navigator.onLine && err instanceof Error) {
				reportUnlessRetried(err, {
					kind: "network_error",
					method,
					url,
					context: networkContext(err, tryNumber, performance.now() - startedAt),
				});
			}
			throw err;
		}
	};
	const { response, attempt } = await attemptFetch(1);

	// The first attempt may have reached the server and deleted the resource
	// before the connection failed: a 404 on the repeat means it is gone.
	if (attempt === 2 && method === "DELETE" && response.status === 404) {
		return new Response(null, { status: 204 });
	}

	if (!response.ok) {
		const body = await response.json().catch(() => ({}));
		// EngramWeb.Plugs.RequireOnboarding's 403 shape. Every caller routes
		// through this one function, so this is the single place that can see
		// it — nothing upstream ever specialised on `error: "onboarding_required"`
		// before, which is why a user stuck behind this gate left no trace at
		// all (see dgonzalez, two visits, zero notes).
		if (response.status === 403 && body.error === "onboarding_required") {
			track("onboarding_blocked", { missing: body.missing, next_step: body.next_step });
		}
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
		const error = new ApiError(
			response.status,
			body.error ?? firstValidationError(body.errors) ?? response.statusText,
		);
		if (response.status >= 500) {
			reportUnlessRetried(error, { kind: `http_${response.status}`, method, url });
		}
		throw error;
	}

	return response;
}

/** The attempt that threw `err` will be retried: its failure is not final, so
 *  drop its report. The final attempt's own error reports if it fails too. */
export function discardRetriedFailure(err: unknown) {
	if (typeof err === "object" && err !== null) {
		pendingReports.delete(err);
	}
}

/** React Query's earlier failed attempts of the request that threw `err`, so
 *  the final report's `attempt` counts every try, not just the last fetch. */
export function noteEarlierAttempts(err: unknown, earlier: number) {
	if (typeof err === "object" && err !== null) {
		const context = pendingReports.get(err)?.context;
		if (context) {
			context.attempt += earlier;
		}
	}
}

export function setTokenGetter(getter: () => Promise<string | null>) {
	tokenGetter = getter;
}

// Shared with the observability beacon buffer (trace.ts), which resolves
// its own Authorization header the same way authFetch does, rather than
// duplicating the tokenGetter plumbing.
export async function getAuthToken(): Promise<string | null> {
	return tokenGetter ? await tokenGetter() : null;
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

/** The resource is gone (deleted, or never existed) rather than some other
 *  failure (network, auth, server error) — the distinction every "show a
 *  missing-state fallback" call site needs. */
export function isNotFound(err: unknown): boolean {
	return err instanceof ApiError && err.status === 404;
}

/** The request named an id the server can't parse (400 "invalid id"), as opposed to a
 *  well-formed id with no resource behind it (404) or some other bad request. */
export function isInvalidId(err: unknown): boolean {
	return err instanceof ApiError && err.status === 400 && err.message === "invalid id";
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
	async get<T>(path: string, opts?: { signal?: AbortSignal }): Promise<T> {
		const res = await authFetch(path, { signal: opts?.signal });
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

	// DELETE takes an optional body. Not decorative: the account-delete flow
	// needs to send a password, and a credential in a query string is written
	// to every access log between the browser and Phoenix — plus Sentry's fetch
	// breadcrumbs, which capture the URL.
	//
	// A network error is retried once (authFetch). Every DELETE route called
	// here repeats safely: connections (oauth, device, pat), admin invites
	// and users re-revoke or re-stamp, folders answer 204 when already gone,
	// and vaults' 404 on a repeat is read as success. Except DELETE /me: it
	// re-sends the password, and a repeat after a success we never saw answers
	// 401 for an account that is already gone, which the UI would show as a
	// failed deletion.
	async del<T>(path: string, body?: unknown): Promise<T | undefined> {
		const res = await authFetch(
			path,
			{
				method: "DELETE",
				body: body === undefined ? undefined : JSON.stringify(body),
			},
			{ retryNetworkError: path !== "/me" },
		);
		// 204 No Content is the conventional REST response for DELETE; tolerate
		// empty bodies so callers don't have to differentiate.
		if (res.status === 204 || res.headers.get("content-length") === "0") {
			return undefined;
		}
		return res.json();
	},

	async getBlob(path: string): Promise<Blob> {
		const res = await authFetch(path);
		return res.blob();
	},
};
