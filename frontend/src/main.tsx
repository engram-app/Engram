import { QueryClientProvider } from "@tanstack/react-query";
import { Component, lazy, type ReactNode, StrictMode, Suspense, use, useMemo } from "react";
import { createRoot } from "react-dom/client";
import { RouterProvider } from "react-router";
import { setApiBase, setTracingEnabled, setWsBase } from "./api/base";
import { queryClient } from "./api/query-client";
import { configPromise, type EngramConfig } from "./config";
import { ConfigProvider } from "./config-context";
import ErrorFallback from "./error-fallback";
import LoadingScreen from "./layout/loading-screen";
import { createAppRouter, installAppRouter } from "./router";
import { captureError } from "./sentry";
import { ThemeProvider } from "./theme/theme-provider";
import "./main.css";

// Stale-deploy self-heal. Every lazy() below (app shell, Clerk provider,
// Toaster, upgrade dialog, …) is a hashed chunk that a deploy can rotate out
// from under an open tab; without this, the next lazy render 404s and the
// throw lands on the route error boundary (router.tsx errorElement). Vite
// fires `vite:preloadError` for failed dynamic-import
// loads — reload once to pick up the fresh index.html + hashes.
// preventDefault() suppresses the rethrow for the reload we handle; the
// 30s guard means a genuinely broken asset host degrades back to the error
// page instead of a reload loop.
window.addEventListener("vite:preloadError", (event) => {
	const KEY = "engram:chunk-reload-at";
	const last = Number(sessionStorage.getItem(KEY) ?? 0);
	if (Date.now() - last < 30_000) {
		return;
	}
	sessionStorage.setItem(KEY, String(Date.now()));
	event.preventDefault();
	window.location.reload();
});

// Sentry lazy singleton + `captureError` reporter moved to ./sentry so the
// route boundary (router.tsx) can report through the same SDK instance without
// a cycle back into this entry module. Opt-in via VITE_SENTRY_DSN; no-op when
// unset. See sentry.ts for the lazy-load + early-error-queue rationale.

// Cloudflare Web Analytics — cookieless RUM beacon. Opt-in via
// VITE_CF_BEACON_TOKEN at build time; no-op when unset so dev /
// self-host builds don't ping the SaaS-side CF analytics account.
// Injected dynamically rather than as a static <script> in
// index.html because the token only exists on the SaaS build path
// (self-host's same bundle would otherwise embed it as a literal).
const cfBeaconToken = import.meta.env.VITE_CF_BEACON_TOKEN;
if (cfBeaconToken) {
	const s = document.createElement("script");
	s.defer = true;
	s.src = "https://static.cloudflareinsights.com/beacon.min.js";
	s.setAttribute("data-cf-beacon", JSON.stringify({ token: cfBeaconToken }));
	document.head.appendChild(s);
}

// PostHog — product analytics. Cookieless by `persistence: 'memory'`
// per [[reference_cookie_audit_2026_05_24]] so the no-banner launch
// posture holds. Autocapture is OFF — explicit events only (see PR8)
// is the single biggest cost lever on the free tier, per
// [[project_observability_stack_plan]]. The identify call happens in
// the Clerk auth provider as soon as the user resolves, NOT here —
// firing it pre-auth would burn a permanent anonymous distinct_id.
// posthog-js (~80 KB) is dynamically imported so it stays OUT of the eager
// main bundle that gates first paint / the login modal. init is fire-and-
// forget and identify happens later in the Clerk auth provider, so nothing on
// the critical path needs posthog synchronously. The clerk-auth-provider
// imports it too, so both resolve to one shared async chunk.
const posthogKey = import.meta.env.VITE_POSTHOG_KEY;
const posthogHost = import.meta.env.VITE_POSTHOG_HOST ?? "https://us.i.posthog.com";
if (posthogKey) {
	import("posthog-js").then(({ default: posthog }) => {
		posthog.init(posthogKey, {
			api_host: posthogHost,
			persistence: "memory",
			autocapture: false,
			capture_pageview: false,
			capture_pageleave: false,
			disable_session_recording: true,
			// Honor the browser's DNT signal as belt-and-suspenders.
			respect_dnt: true,
		});
	});
}

// Both auth providers are declared lazy at module scope; only one is
// instantiated per page load based on resolved config (BootstrapGate).
const ClerkAuthProvider = lazy(() => import("./auth/clerk-auth-provider"));
const LocalAuthProvider = lazy(() => import("./auth/local-auth-provider"));

// sonner (~32 KB) is toast plumbing, not first-paint UI — lazy so it loads in
// parallel after mount instead of inside the eager bundle that gates the
// sign-in page. Worst case a toast fired before the chunk lands is dropped;
// toasts are interaction-driven, so that window is effectively unreachable.
const Toaster = lazy(() => import("@/components/ui/sonner").then((m) => ({ default: m.Toaster })));

// Toasts are cosmetic: if the sonner chunk is truly unloadable (network flake
// that survives the vite:preloadError reload), losing toasts must not take
// down an otherwise working app via RootErrorBoundary.
class OptionalBoundary extends Component<{ children: ReactNode }, { failed: boolean }> {
	state = { failed: false };

	static getDerivedStateFromError() {
		return { failed: true };
	}

	componentDidCatch(error: unknown) {
		console.warn("[toaster] disabled — chunk failed to load:", error);
	}

	render() {
		return this.state.failed ? null : this.props.children;
	}
}

// Bootstrap chain: `use(configPromise)` suspends until config resolves
// (window injection → /config.json → defaults). Once resolved, build the
// runtime router (route shape depends on auth provider + billingEnabled)
// and install it so module-level consumers like clerk-auth-provider can
// imperatively navigate via `getAppRouter()`.
function AppShell({ config }: { config: EngramConfig }) {
	// Dev-only crash trigger for eyeballing ErrorFallback. Throws HERE, above
	// RouterProvider, on purpose: a throwing *route* would be caught by React
	// Router's own error boundary, not the outer RootErrorBoundary we're
	// styling. Visit `?boom` to see the real crash page. Stripped from prod
	// builds by the import.meta.env.DEV gate.
	if (import.meta.env.DEV && new URLSearchParams(window.location.search).has("boom")) {
		throw new Error("Intentional crash (?boom) — testing ErrorFallback");
	}

	const AuthProvider = config.authProvider === "clerk" ? ClerkAuthProvider : LocalAuthProvider;
	// Memoize so StrictMode's double-render + any future ConfigProvider
	// updates don't blow away the router instance + its history stack.
	const router = useMemo(() => {
		const r = createAppRouter(config);
		installAppRouter(r);
		return r;
	}, [config]);

	return (
		<ConfigProvider config={config}>
			<ThemeProvider>
				<Suspense fallback={<LoadingScreen />}>
					<AuthProvider>
						<QueryClientProvider client={queryClient}>
							<RouterProvider router={router} />
							{/* Own boundary — a suspending Toaster must not trip the outer
							    fallback and blank the app to LoadingScreen. */}
							<OptionalBoundary>
								<Suspense fallback={null}>
									<Toaster richColors closeButton />
								</Suspense>
							</OptionalBoundary>
						</QueryClientProvider>
					</AuthProvider>
				</Suspense>
			</ThemeProvider>
		</ConfigProvider>
	);
}

function BootstrapGate() {
	const config = use(configPromise);
	// Install module-level apiBase/wsBase BEFORE any child component mounts.
	// The singleton `api` object in src/api/client.ts and the WebSocket call
	// sites read these via getApiBase()/getWsBase(); they need a value
	// populated before AuthGuard fires its first fetch on mount.
	setApiBase(config.apiBase);
	setWsBase(config.wsBase);
	setTracingEnabled(config.tracingEnabled);
	return <AppShell config={config} />;
}

// Replaces Sentry.ErrorBoundary so the SDK can load lazily. Capture waits on
// `sentryReady`, then surfaces the eventId + an honest `reported` flag to
// ErrorFallback (only claimed once captureException actually dispatched).
interface RootErrorBoundaryState {
	hasError: boolean;
	error: unknown;
	eventId?: string;
	reported: boolean;
}

class RootErrorBoundary extends Component<{ children: ReactNode }, RootErrorBoundaryState> {
	state: RootErrorBoundaryState = { hasError: false, error: null, reported: false };

	static getDerivedStateFromError(error: unknown): Partial<RootErrorBoundaryState> {
		return { hasError: true, error };
	}

	componentDidCatch(error: unknown, errorInfo: React.ErrorInfo) {
		// captureError passes errorInfo through to captureReactException (attaches
		// the React componentStack), and resolves to an eventId only once the lazy
		// SDK actually dispatched — so `reported` is never claimed falsely.
		captureError(error, errorInfo).then((eventId) => {
			if (eventId) {
				this.setState({ eventId, reported: true });
			}
		});
	}

	render() {
		if (this.state.hasError) {
			return (
				<ErrorFallback
					error={this.state.error}
					eventId={this.state.eventId}
					reported={this.state.reported}
				/>
			);
		}
		return this.props.children;
	}
}

createRoot(document.getElementById("root")!).render(
	<RootErrorBoundary>
		<StrictMode>
			<Suspense fallback={<LoadingScreen />}>
				<BootstrapGate />
			</Suspense>
		</StrictMode>
	</RootErrorBoundary>,
);
