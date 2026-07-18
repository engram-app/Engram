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
				Sentry.init({
					dsn: sentryDsn,
					environment: import.meta.env.MODE,
					release: import.meta.env.VITE_GIT_SHA,
					integrations: [],
					// sendDefaultPii=false (SDK default) keeps cookies + the
					// Authorization header out of breadcrumbs even if the SDK's
					// own scrubbing misses something. Restated for documentation.
					sendDefaultPii: false,
				});
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
 * Report a crash and resolve to the Sentry eventId, or `undefined` when
 * reporting is disabled (no DSN) or the SDK chunk failed to load. Callers derive
 * an honest `reported` flag from a defined return — never claim "reported" with
 * no transport behind it.
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
	return errorInfo
		? Sentry.captureReactException(error, errorInfo)
		: Sentry.captureException(error);
}
