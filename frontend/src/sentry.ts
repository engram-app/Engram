import type { Breadcrumb } from "@sentry/react";
import type { ErrorInfo } from "react";

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
				return Sentry as SentrySdk;
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
	// Keep the HOST and the FIRST path segment; redact the rest.
	//
	// Scrubbing everything made the output useless at the moment reporting was
	// switched on: "/:seg/:seg" cannot tell /api/search from /api/folders, and
	// dropping the origin hid which service answered. Neither the hostname nor
	// a first segment like "api" or "attachments" is user data — the note path,
	// the filename and the credential all live deeper — so keeping them costs
	// nothing and restores the ability to see which endpoint failed.
	const segments = parsed.pathname.split("/");
	const path = segments.map((seg, i) => (seg && i > 1 ? ":seg" : seg)).join("/");
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
	const referer = event.request?.headers?.Referer;
	if (event.request?.headers && typeof referer === "string") {
		event.request.headers.Referer = scrubUrl(referer);
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
