import { QueryClientProvider } from "@tanstack/react-query";
import { Component, lazy, type ReactNode, StrictMode, Suspense, use, useMemo } from "react";
import { createRoot } from "react-dom/client";
import { RouterProvider } from "react-router";
import { initAnalytics } from "./analytics/init";
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

// PostHog — product analytics. See ./analytics/init for the init options and
// their rationale (cookieless posture, no-autocapture, GPC guard). Fire-and-
// forget: init is async (posthog-js is dynamically imported so it stays OUT
// of the eager main bundle) and identify happens later in the Clerk auth
// provider, so nothing on the critical path needs it synchronously. The
// clerk-auth-provider imports posthog-js too, so both resolve to one shared
// async chunk.
initAnalytics(import.meta.env.VITE_POSTHOG_KEY ?? "");

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
	// styling. Visit `?boom` to see the real crash page; use `?routeboom`
	// (router.tsx) for the route-level twin. Stripped from prod builds by the
	// import.meta.env.DEV gate.
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
