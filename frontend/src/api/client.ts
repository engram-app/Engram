import { track } from "../analytics/track";
import { rlog } from "../observability/remote-log";
import { newTraceContext, tracingEnabled } from "../observability/trace";
import { scrubUrl } from "../sentry";
import { getActiveVaultId } from "./active-vault";
import { getApiBase, joinApiUrl } from "./base";
import { getDeviceId } from "./device-id";
import { type NetworkContext, networkContext, offlineMark } from "./network-context";

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

/** `retry-after` in seconds, when the server sent a numeric one. */
function parseRetryAfter(response: Response): number | undefined {
	const secs = Number(response.headers.get("retry-after"));
	return response.headers.has("retry-after") && Number.isFinite(secs) ? secs : undefined;
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

/** Errors whose reporting the api client owns: every fetch rejection (a
 *  network failure, reported or deliberately not, e.g. offline) and every
 *  5xx. A caller that handles a failure checks this before capturing it, so
 *  nothing is reported twice and nothing else goes unreported. */
const ownedFailures = new WeakSet<object>();

/** One run of a query's queryFn. React Query marks it `retried` when it decides
 *  to run the queryFn again, so every request made in that run is dropped,
 *  however the queryFn combined or wrapped their errors (Promise.all, a
 *  rethrow). Linking by the thrown error alone missed exactly those. */
interface QueryAttempt {
	/** Failed attempts before this one, for the report's `attempt`. */
	earlier: number;
	retried: boolean;
}

// The attempt whose queryFn is running right now. A request belongs to it if
// authFetch is CALLED synchronously inside the queryFn, which every queryFn
// here does for its first request; one made after an `await` falls back to
// the thrown-error link below.
let currentQueryAttempt: QueryAttempt | null = null;

/** Report `err` once the current attempt has settled, unless a retry claims it:
 *  its query attempt is marked retried, or (outside a query attempt) React
 *  Query discards this exact error. React Query decides to retry inside the
 *  rejection's microtasks; a timer runs after them. A caller outside React
 *  Query never claims, so it still reports. */
function reportUnlessRetried(err: object, failure: Failure, queryAttempt: QueryAttempt | null) {
	if (queryAttempt && failure.context) {
		failure.context.attempt += queryAttempt.earlier;
	}
	pendingReports.set(err, failure);
	setTimeout(() => {
		const pending = pendingReports.get(err);
		pendingReports.delete(err);
		if (pending && !queryAttempt?.retried) {
			sendReport(pending);
		}
	}, 0);
}

/** Methods safe to send twice, so a network error gets one more try here.
 *  Not GET: React Query already retries queries. Not POST/PATCH: not
 *  idempotent. DELETE: every route the SPA calls was checked for a safe repeat
 *  (see api.del). PUT is idempotent by HTTP's definition, but the SPA sends
 *  none today and no PUT route has been audited; add it with that audit. */
const RETRY_ONCE_METHODS = new Set(["DELETE"]);
const RETRY_DELAY_MS = 300;

async function authFetch(
	path: string,
	options: RequestInit = {},
	{ retryNetworkError = true } = {},
): Promise<Response> {
	// Before the first await: only the synchronous part of a queryFn is inside it.
	const queryAttempt = currentQueryAttempt;
	const token = await getAuthToken();

	const headers = new Headers(options.headers);
	if (!headers.has("Content-Type")) {
		headers.set("Content-Type", "application/json");
	}
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
		const offlineSince = offlineMark();
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
			if (err instanceof Error) {
				ownedFailures.add(err);
			}
			if (!aborted && navigator.onLine && err instanceof Error) {
				reportUnlessRetried(
					err,
					{
						kind: "network_error",
						method,
						url,
						context: networkContext(err, tryNumber, performance.now() - startedAt, offlineSince),
					},
					queryAttempt,
				);
			}
			throw err;
		}
	};
	const { response, attempt } = await attemptFetch(1);

	// A 404 on the repeat of a DELETE: either the first attempt reached the
	// server and deleted it before the connection failed, or it never arrived
	// and the id was wrong all along. The user's goal (it is gone) holds either
	// way, and failing would read as "delete failed" for a delete that worked,
	// so it resolves. The ambiguity is logged, so a wrong-id bug that only
	// shows up when a network error coincides is still countable in Loki.
	if (attempt === 2 && method === "DELETE" && response.status === 404) {
		rlog().warn("api_request", `delete_retry_not_found DELETE ${scrubUrl(url)}`);
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
			parseRetryAfter(response),
		);
		if (response.status >= 500) {
			ownedFailures.add(error);
			reportUnlessRetried(error, { kind: `http_${response.status}`, method, url }, queryAttempt);
		}
		throw error;
	}

	return response;
}

/** The attempt that threw `err` will be retried: its failure is not final, so
 *  drop its report. The final attempt's own error reports if it fails too. */
/** True when the api client already reports (or deliberately skips) this
 *  failure: a network error or a 5xx. Anything else is the caller's to report. */
export function isApiClientFailure(err: unknown): boolean {
	return typeof err === "object" && err !== null && ownedFailures.has(err);
}

/** Run one attempt of a query's queryFn as `attempt` (see QueryAttempt). */
export function runInQueryAttempt<T>(attempt: QueryAttempt, fn: () => T): T {
	const outer = currentQueryAttempt;
	currentQueryAttempt = attempt;
	try {
		return fn();
	} finally {
		currentQueryAttempt = outer;
	}
}

export function discardRetriedFailure(err: unknown) {
	if (typeof err === "object" && err !== null) {
		pendingReports.delete(err);
	}
}

/** A mutation's earlier failed attempts of the request that threw `err`, so
 *  the final report's `attempt` counts every try, not just the last fetch.
 *  (A query's come from its QueryAttempt.) */
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

export type { QueryAttempt };

export class ApiError extends Error {
	constructor(
		public status: number,
		message: string,
		public retryAfterS?: number,
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

	/** Raw bytes in the body, metadata in the query (`POST /attachments`). */
	async postRaw<T>(
		path: string,
		body: Blob,
		query: Record<string, string | number | undefined>,
		opts?: { signal?: AbortSignal },
	): Promise<T> {
		const params = new URLSearchParams();
		for (const [k, v] of Object.entries(query)) {
			if (v !== undefined) {
				params.set(k, String(v));
			}
		}
		const res = await authFetch(`${path}?${params}`, {
			method: "POST",
			body,
			headers: { "Content-Type": "application/octet-stream" },
			signal: opts?.signal,
		});
		return res.json();
	},

	async putRaw<T>(path: string, body: Blob, opts?: { signal?: AbortSignal }): Promise<T> {
		const res = await authFetch(path, {
			method: "PUT",
			body,
			headers: { "Content-Type": "application/octet-stream" },
			signal: opts?.signal,
		});
		return res.json();
	},

	async getBlob(path: string): Promise<Blob> {
		const res = await authFetch(path);
		return res.blob();
	},
};
