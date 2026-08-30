import type { Breadcrumb } from "@sentry/react";
import type { ErrorInfo } from "react";
import { ROUTES, VAULT_PREFIX } from "./routes";

/** First path segments that are ours, not the user's.
 *
 *  Derived from ROUTES where possible so a new SPA route cannot silently start
 *  being redacted (and a renamed one cannot silently start leaking). The rest
 *  are segments with no ROUTES entry: router-literal paths, the API prefixes
 *  fetch breadcrumbs carry, and Vite's asset dir.
 *
 *  Anything NOT here is treated as user data. That is the safe default — the
 *  cost of a miss is one unhelpful ":seg" in a stack trace, versus a vault
 *  name shipped to a third party. */
const KNOWN_FIRST_SEGMENTS = new Set<string>([
	// flatMap, not map+filter(Boolean): under noUncheckedIndexedAccess the
	// index is `string | undefined` and filter(Boolean) does not narrow it.
	...Object.values(ROUTES).flatMap((route) => {
		const [, segment] = route.split("/");
		return segment ? [segment] : [];
	}),
	// The vault prefix. Keeping it un-redacted is safe AND strictly better for
	// privacy than the old root-level shape: the slug is now always segment 2,
	// which is unconditionally ":seg". Previously the slug WAS segment 1, so it
	// stayed out of Sentry only because it missed this allowlist.
	VAULT_PREFIX.slice(1),
	// Router literals with no ROUTES constant.
	"onboard",
	"settings",
	"note",
	"__qc",
	// Backend prefixes the SPA actually fetches same-origin (self-host shape;
	// on SaaS these live on the API host, which is not our origin and so keeps
	// its first segment anyway).
	"api",
	"attachments",
	"socket",
	// Vite build output.
	"assets",
]);

// Lazy Sentry singleton + crash reporter. Extracted from main.tsx so BOTH the
// root boundary (main.tsx, catches bootstrap/app-shell throws above the router)
// and the route boundary (router.tsx errorElement, catches route render throws
// that React Router intercepts before they can reach the root) report through
// ONE SDK instance. main.tsx imports router.tsx, so the reporter can't live in
// main.tsx without a cycle back into the entry module — hence this leaf module.
//
// Opt-in via VITE_SENTRY_DSN at build time. No-op (zero network, zero SDK in the
// eager bundle) when unset, so dev / self-host builds never ping the SaaS Sentry.
// The SDK is dynamically imported so it stays out of the bundle that gates the
// sign-in page; the early-error queue bridges the pre-init window so bootstrap
// crashes that fire before the chunk lands still report. sentryReady resolves to
// null when the chunk itself fails to load (ad-blockers match "sentry" in asset
// URLs; stale-tab 404s) — callers must tolerate that and it must NOT surface as
// an unhandled rejection.
const sentryDsn = import.meta.env.VITE_SENTRY_DSN;

type SentrySdk = typeof import("@sentry/react");

const earlyErrors: unknown[] = [];
const onEarlyError = (e: ErrorEvent) => earlyErrors.push(e.error ?? e.message);
const onEarlyRejection = (e: PromiseRejectionEvent) => earlyErrors.push(e.reason);
if (sentryDsn) {
	window.addEventListener("error", onEarlyError);
	window.addEventListener("unhandledrejection", onEarlyRejection);
}

export const sentryReady: Promise<SentrySdk | null> | null = sentryDsn
	? import("@sentry/react")
			.then((Sentry) => {
				Sentry.init(sentryInitOptions(sentryDsn));
				// The SDK's own global handlers are live from here; hand it the
				// backlog and retire the temporary listeners.
				window.removeEventListener("error", onEarlyError);
				window.removeEventListener("unhandledrejection", onEarlyRejection);
				for (const err of earlyErrors.splice(0)) {
					Sentry.captureException(err);
				}
				return Sentry;
			})
			.catch((err) => {
				window.removeEventListener("error", onEarlyError);
				window.removeEventListener("unhandledrejection", onEarlyRejection);
				console.warn("[sentry] SDK failed to load — crash reporting disabled:", err);
				return null;
			})
	: null;

/**
 * Report a crash and resolve to the Sentry eventId, or `undefined` when the
 * event was NOT delivered — reporting disabled (no DSN), SDK chunk failed to
 * load, capture threw, or the envelope never reached the ingest host. Callers
 * derive an honest `reported` flag from a defined return.
 *
 * captureException/captureReactException mint the eventId locally and return it
 * BEFORE the network round-trip, so an id alone is not proof of delivery — the
 * envelope POST to *.ingest.sentry.io is fire-and-forget and is routinely
 * dropped (uBlock/EasyPrivacy block sentry.io, offline, ratelimit) even though
 * the same-origin SDK chunk loaded fine. So we gate the returned id on
 * flush() actually delivering: the UI must never say "reported" for an event
 * that never left the browser. Never throws — the whole point is that the
 * crash-reporting path can't itself become an unhandled rejection.
 *
 * Pass `errorInfo` for React render crashes (a class boundary's componentDidCatch
 * has it) to attach the component stack via captureReactException — the same call
 * Sentry.ErrorBoundary makes. Route errors from useRouteError carry no component
 * stack, so they omit it and fall back to captureException.
 */

export async function captureError(
	error: unknown,
	errorInfo?: ErrorInfo,
): Promise<string | undefined> {
	const Sentry = await sentryReady;
	if (!Sentry) {
		return;
	}
	try {
		const eventId = errorInfo
			? Sentry.captureReactException(error, errorInfo)
			: Sentry.captureException(error);
		// flush resolves true only if all queued envelopes were sent within the
		// timeout; false on drop/timeout. Gate the id on real delivery.
		const delivered = await Sentry.flush(2000);
		return delivered ? eventId : undefined;
	} catch (e) {
		console.warn("[sentry] capture failed:", e);
	}
}

/** Replace a URL's path segments and query VALUES with placeholders.
 *
 *  Note paths, titles, attachment filenames and single-use credentials all
 *  travel in URLs here (`/attachments/Medical/labs.pdf`, `?code=`, `?token=`),
 *  and the SDK attaches `request.url` to every event plus a breadcrumb to every
 *  fetch. Keeping the shape is enough to debug a route; the contents are the
 *  user's. Parsed against a dummy base so relative URLs (what fetch breadcrumbs
 *  actually carry) work; that also means nearly any string resolves and gets
 *  scrubbed, which is the safe direction. The catch is a last resort: throwing
 *  inside beforeSend would drop the crash report entirely. */

export function scrubUrl(url: string): string {
	let parsed: URL;
	try {
		parsed = new URL(url, "http://x.invalid");
	} catch {
		return url;
	}
	// Keep the HOST and the first path segment ONLY when that segment is a
	// route we ship; redact everything else.
	//
	// Scrubbing everything made the output useless at the moment reporting was
	// switched on: "/:seg/:seg" cannot tell /api/search from /api/folders, and
	// dropping the origin hid which service answered.
	//
	// But "keep segment 1" is wrong for OUR OWN ORIGIN. `/v/:slug` (router.tsx) is
	// the VAULT route, and the slug is slugify(vault.name) — a user-typed name.
	// A vault called "Divorce 2026" put `divorce-2026` into every navigation
	// breadcrumb and every event's request.url, on the app's most-travelled
	// route.
	//
	// The allowlist only applies there. On any OTHER origin a first segment
	// cannot be a vault slug: SaaS calls the API on a separate host
	// (`api.engram.page`), and `joinApiUrl` STRIPS the `/api` prefix when an
	// apiBase is set (api/base.ts) — so those URLs read `/search`, `/folders`,
	// `/notes`. Running the route allowlist over them redacted every endpoint
	// name in prod, which is the exact "cannot tell /api/search from
	// /api/folders" uselessness this function was written to avoid. And SaaS is
	// the only deployment with a DSN, so that was the only behaviour that ran.
	//
	// Relative URLs are the app's own (that is what fetch breadcrumbs carry on
	// self-host), so they get the allowlist too.
	// Fails CLOSED. With `window` absent (a worker, SSR, a test that stubs it
	// away) an unknown origin is treated as ours, so the allowlist applies and
	// an unrecognised first segment is redacted. The other direction would keep
	// a vault slug in exactly the context nobody thought to check.
	const relative = parsed.hostname === "x.invalid";
	const noWindow = typeof window === "undefined";
	const ownOrigin = relative || noWindow || parsed.origin === window.location.origin;
	const segments = parsed.pathname.split("/");
	const path = segments
		.map((seg, i) => {
			if (!seg) {
				return seg;
			}
			if (i === 1) {
				return !ownOrigin || KNOWN_FIRST_SEGMENTS.has(seg) ? seg : ":seg";
			}
			return ":seg";
		})
		.join("/");
	const keys = [...parsed.searchParams.keys()];
	const query = keys.length > 0 ? `?${keys.map((k) => `${k}=:v`).join("&")}` : "";
	const host = parsed.hostname === "x.invalid" ? "" : parsed.origin;
	return host + path + query;
}

/** Console and DOM breadcrumbs are dropped outright, and every other kind has
 *  its URL scrubbed.
 *
 *  Console args are arbitrary values a developer passed to console.error —
 *  attachment paths today, anything tomorrow — and DOM breadcrumbs serialize
 *  `title`/`alt`/`aria-label` off the clicked element AND five ancestors, which
 *  in this app carry note paths, filenames and frontmatter values. Neither is
 *  worth a privacy review on every future edit. */
export function scrubBreadcrumb(crumb: Breadcrumb): Breadcrumb | null {
	if (crumb.category === "console" || crumb.category?.startsWith("ui.")) {
		return null;
	}
	if (typeof crumb.data?.url === "string") {
		crumb.data.url = scrubUrl(crumb.data.url);
	}
	if (typeof crumb.data?.to === "string") {
		crumb.data.to = scrubUrl(crumb.data.to);
	}
	if (typeof crumb.data?.from === "string") {
		crumb.data.from = scrubUrl(crumb.data.from);
	}
	return crumb;
}

/** httpContextIntegration attaches `request.url` AND `request.headers`, and
 *  those headers include `Referer` — which, while a `?token=` or `?code=` is
 *  still in the address bar, is the full URL of the page. Scrubbing the url and
 *  leaving the header would have missed the same credential by one field. */
export function scrubEvent<
	T extends { request?: { url?: string; headers?: Record<string, string> } },
>(event: T): T {
	if (event.request?.url) {
		event.request.url = scrubUrl(event.request.url);
	}
	// Case-insensitive: httpContextIntegration capitalizes it today, but header
	// names are case-insensitive by spec and an exact-key match is the same
	// "missed it by one field" mode this function exists to close.
	const headers = event.request?.headers;
	if (headers) {
		for (const key of Object.keys(headers)) {
			if (key.toLowerCase() === "referer" && typeof headers[key] === "string") {
				headers[key] = scrubUrl(headers[key]);
			}
		}
	}
	return event;
}

/** The exact options passed to `Sentry.init`. Exported so a test can assert the
 *  scrubbers are actually WIRED — with them inline, deleting the two hook lines
 *  left every test green while DOM breadcrumbs (which serialize title/alt/
 *  aria-label off the target and five ancestors) shipped again. */
export function sentryInitOptions(dsn: string) {
	return {
		dsn,
		environment: import.meta.env.MODE,
		release: import.meta.env.VITE_GIT_SHA,
		// `integrations: []` does NOT disable the defaults — the SDK MERGES this
		// array with getDefaultIntegrations() and only `defaultIntegrations: false`
		// opts out. So breadcrumbs and httpContext were live the whole time, which
		// is what makes the scrubbing below necessary rather than decorative.
		integrations: [],
		// sendDefaultPii=false (SDK default) keeps cookies + the Authorization
		// header out of breadcrumbs even if the SDK's own scrubbing misses
		// something. Restated for documentation.
		sendDefaultPii: false,
		beforeBreadcrumb: scrubBreadcrumb,
		beforeSend: scrubEvent,
	};
}
