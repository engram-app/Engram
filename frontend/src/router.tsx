import { lazy, type ReactNode, Suspense } from "react";
import { createBrowserRouter, Navigate, Outlet } from "react-router";
import AuthGuard from "./auth/auth-guard";
import CatchAllRoute from "./auth/catch-all-route";
import SignInPage from "./auth/sign-in";
import SignUpPage from "./auth/sign-up";
import WaitlistPage from "./auth/waitlist";
import { UpgradeDialogProvider } from "./billing/upgrade-dialog-provider";
import type { EngramConfig } from "./config";
import LoadingScreen from "./layout/loading-screen";
import RouteErrorBoundary from "./route-error-boundary";
import { ROUTES } from "./routes";
import LoadingPane from "./viewer/loading-pane";

// Route-level code splitting. The viewer stack alone (remark/rehype +
// KaTeX wiring + CodeMirror behind NotePage) dominated a 1.78 MB main
// chunk that even the sign-in page had to parse. Entry surfaces
// (sign-in/up, guards) stay eager; everything behind navigation —
// including the authenticated app shell — loads on demand.

// The app-shell layouts all resolve through ONE barrel module so they share a
// single async chunk (no gate → shell → layout chunk waterfall). This is what
// keeps yjs / phoenix / react-joyride / react-resizable-panels / the folder
// tree out of the eager bundle that gates the sign-in page.
const AppLayout = lazy(() => import("./layout/app-shell").then((m) => ({ default: m.AppLayout })));
const OnboardingGate = lazy(() =>
	import("./layout/app-shell").then((m) => ({ default: m.OnboardingGate })),
);
const OnboardingShell = lazy(() =>
	import("./layout/app-shell").then((m) => ({ default: m.OnboardingShell })),
);
const SettingsLayout = lazy(() =>
	import("./layout/app-shell").then((m) => ({ default: m.SettingsLayout })),
);
// Onboarding entry surface — same one-chunk barrel pattern.
const OnboardLayout = lazy(() =>
	import("./onboarding/onboard-entry").then((m) => ({ default: m.OnboardLayout })),
);
const OnboardRedirect = lazy(() =>
	import("./onboarding/onboard-entry").then((m) => ({ default: m.OnboardRedirect })),
);
const Dashboard = lazy(() => import("./viewer/dashboard"));
// /note/:id resolves to the note OR attachment viewer (VaultItemPage owns the
// lazy NotePage/AttachmentPage chunks).
const VaultItemPage = lazy(() => import("./viewer/vault-item-page"));
const BillingPage = lazy(() => import("./billing/billing-page"));
const AdminPanel = lazy(() => import("./features/admin/AdminPanel"));
const ResetPasswordPage = lazy(() => import("./features/auth/ResetPasswordPage"));
const DeviceLinkPage = lazy(() => import("./device/device-link-page"));
const ConnectionsPage = lazy(() => import("./settings/connections-page"));
const VaultsPage = lazy(() => import("./settings/vaults-page"));
const OAuthAuthorizePage = lazy(() => import("./oauth/oauth-authorize-page"));
const AgreementPage = lazy(() => import("./onboarding/agreement-page"));
const OnboardBillingPage = lazy(() => import("./onboarding/onboard-billing-page"));
const OnboardToolsPage = lazy(() => import("./onboarding/onboard-tools-page"));
const OnboardVaultPage = lazy(() => import("./onboarding/onboard-vault-page"));

const routeFallback = <LoadingPane />;

function suspended(el: ReactNode) {
	return <Suspense fallback={routeFallback}>{el}</Suspense>;
}

// Layout-level boundary: full-screen fallback matching AuthGuard's own
// loading state, so the auth-resolve → shell-chunk-fetch handoff doesn't
// flash between two different spinners.
function suspendedScreen(el: ReactNode) {
	return <Suspense fallback={<LoadingScreen />}>{el}</Suspense>;
}

// Root layout — mounts the UpgradeDialogProvider INSIDE the router so the
// dialog's `useNavigate` works, and so any nested API call that 402s opens
// the modal via the module-level handler. Wrapping `RouterProvider` from
// `main.tsx` would not give the provider router context.
function RootLayout() {
	// Dev-only route-level crash trigger — the twin of main.tsx's `?boom` (which
	// throws ABOVE the router to hit RootErrorBoundary). This throws INSIDE the
	// router, so it exercises the route errorElement (RouteErrorBoundary) — the
	// path a real route crash like the note editor takes. Visit `?routeboom`.
	// Stripped from prod by the import.meta.env.DEV gate.
	if (import.meta.env.DEV && new URLSearchParams(window.location.search).has("routeboom")) {
		throw new Error("Intentional crash (?routeboom) — testing the route error boundary");
	}
	return (
		<UpgradeDialogProvider>
			<Outlet />
		</UpgradeDialogProvider>
	);
}

// Router is constructed inside `createAppRouter(config)` so the auth-provider
// and billing-enabled branches can read runtime config. Module-level
// consumers (e.g. clerk-auth-provider's `routerPush`) read `appRouter`,
// which BootstrapGate populates BEFORE first render via `installAppRouter`.
type AppRouter = ReturnType<typeof createBrowserRouter>;

let _appRouter: AppRouter | null = null;

export function installAppRouter(r: AppRouter) {
	_appRouter = r;
}

// Lazy getter used by code paths that need to imperatively navigate
// (e.g. Clerk's routerPush). Throws if invoked before BootstrapGate
// mounted — that would be a wiring regression worth surfacing loudly.
export function getAppRouter(): AppRouter {
	if (!_appRouter) {
		throw new Error("Router accessed before installAppRouter() ran");
	}
	return _appRouter;
}

export function createAppRouter(config: EngramConfig): AppRouter {
	// Lazy so Clerk-only code (the account page pulls in @clerk/react hooks)
	// stays out of the main chunk for local self-host builds.
	const AccountPage = lazy(() =>
		config.authProvider === "clerk"
			? import("./settings/account-page")
			: import("./settings/account-page-local"),
	);

	return createBrowserRouter([
		{
			element: <RootLayout />,
			// Global route error boundary. RR bubbles any descendant route throw to
			// the nearest errorElement; this is the only one, so every route crash
			// (incl. lazy-chunk load failures past the vite:preloadError guard)
			// renders the app's ErrorFallback instead of RR's default page.
			errorElement: <RouteErrorBoundary />,
			children: [
				// Public routes
				{ path: ROUTES.SIGN_IN, element: <SignInPage /> },
				{ path: ROUTES.SIGN_UP, element: <SignUpPage /> },
				{ path: ROUTES.WAITLIST, element: <WaitlistPage /> },
				// Public reset — the one-time token IS the credential.
				{ path: "/reset-password", element: suspended(<ResetPasswordPage />) },

				// Authenticated routes
				{
					element: <AuthGuard />,
					children: [
						// Onboarding wizard — itself protected by AuthGuard, but NOT by
						// OnboardingGate (would redirect-loop).
						{
							path: "/onboard",
							element: suspendedScreen(<OnboardLayout />),
							children: [
								{ index: true, element: suspended(<OnboardRedirect />) },
								{ path: "agreement", element: suspended(<AgreementPage />) },
								{ path: "billing", element: suspended(<OnboardBillingPage />) },
								{ path: "tools", element: suspended(<OnboardToolsPage />) },
								{ path: "vault", element: suspended(<OnboardVaultPage />) },
							],
						},

						// /link is reachable mid-onboarding — the wizard's Obsidian branch
						// requires the user to complete device-flow here before progressing.
						// Sits OUTSIDE the OnboardingGate to dodge the redirect-to-/onboard.
						{ path: ROUTES.DEVICE_LINK, element: suspended(<DeviceLinkPage />) },

						// OAuth consent — reachable mid-onboarding so an MCP client (e.g.
						// Claude Desktop) initiating a connection during signup can complete
						// the OAuth dance without being bounced to /onboard.
						{ path: ROUTES.OAUTH_CONSENT, element: suspended(<OAuthAuthorizePage />) },

						// Dashboard tree — gated by OnboardingGate.
						{
							element: suspendedScreen(<OnboardingGate />),
							children: [
								{
									// OnboardingShell wraps the dashboard tree so the tour offer,
									// first-vault modal, and checklist only mount on the main app
									// surface — NOT on /settings/*, /device-link, or /oauth.
									element: suspendedScreen(
										<OnboardingShell>
											<Outlet />
										</OnboardingShell>,
									),
									children: [
										{
											element: suspendedScreen(<AppLayout />),
											children: [
												{ path: ROUTES.HOME, element: suspended(<Dashboard />) },
												{ path: "/note/:id", element: suspended(<VaultItemPage />) },
												{
													path: "settings",
													element: suspended(<SettingsLayout />),
													children: [
														{
															index: true,
															element: <Navigate to="account" replace />,
														},
														{
															path: "account",
															element: (
																<Suspense
																	fallback={<p className="text-muted-foreground">Loading…</p>}
																>
																	<AccountPage />
																</Suspense>
															),
														},
														{ path: "vaults", element: suspended(<VaultsPage />) },
														{ path: "connections", element: suspended(<ConnectionsPage />) },
														{
															path: "api-keys",
															element: <Navigate to="/settings/connections" replace />,
														},
														...(config.billingEnabled
															? [{ path: "billing", element: suspended(<BillingPage />) }]
															: []),
														...(config.authProvider === "local"
															? [{ path: "admin", element: suspended(<AdminPanel />) }]
															: []),
													],
												},
											],
										},
									],
								},
							],
						},
					],
				},

				// Catch-all — auth-aware: signed-out visitors are bounced to sign-in
				// (with return_to), signed-in users see the real 404. A typo for a
				// logged-in user is just a typo; for a logged-out one there's nothing
				// to do on a 404 but authenticate.
				{ path: "*", element: <CatchAllRoute /> },
			],
		},
	]);
}
