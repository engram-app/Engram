import { ClerkProvider, useAuth, useClerk } from "@clerk/react";
import { dark } from "@clerk/themes";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import AuthPanel from "@/layout/auth-panel";
import { notify } from "@/lib/notify";
import { heading } from "@/lib/ui-classes";
import { setTokenGetter } from "../api/client";
import { useMe } from "../api/queries";
import { queryClient } from "../api/query-client";
import { useConfig } from "../config-context";
import { useT } from "../i18n/locale-provider";
import type { Locale } from "../i18n/locales";
import { type ClerkLocalization, clerkLocalizationLoaders } from "../i18n/vendor-locales";
import { getAppRouter } from "../router";
import { ROUTES } from "../routes";
import { captureError, sentryReady } from "../sentry";
import { useTheme } from "../theme/theme-provider";
import { type AuthAdapter, AuthContext } from "./auth-context";
import { clearHttpCache } from "./clear-http-cache";
import { rememberSignupUser } from "./signup-rejection";
import { useClearQueryCacheOnUserChange } from "./use-clear-query-cache-on-user-change";
import { useIdentifyUserOnAuthChange } from "./use-identify-user-on-auth-change";
import { useWipeCrdtOnUserChange } from "./use-wipe-crdt-on-user-change";

// Map Clerk onto Engram's CSS design tokens. The Clerk React components render
// in-DOM (not an iframe), so these var() references resolve against the document.
// The dark baseTheme (applied reactively below) is what flips Clerk's own
// surface/brand-glyph handling — colorPrimary etc. then re-skin it to brand.
const clerkVariables = {
	colorPrimary: "var(--primary)",
	colorText: "var(--foreground)",
	colorTextSecondary: "var(--muted-foreground)",
	colorBackground: "var(--card)",
	colorInputBackground: "var(--background)",
	colorInputText: "var(--foreground)",
	colorNeutral: "var(--foreground)",
	borderRadius: "var(--radius)",
	fontFamily: "'Inter Variable', system-ui, sans-serif",
};

const clerkElements = {
	cardBox: "border border-border shadow-2xl shadow-primary/10",
	card: "bg-card",
	footer: "bg-transparent",
};

// One toast for the whole sign-out: loading, then dismissed or replaced by the error.
const SIGN_OUT_TOAST = "sign-out";
const SIGN_OUT_TIMEOUT_MS = 15_000;

function ClerkAdapterInner({ children }: { children: React.ReactNode }) {
	const { isLoaded, isSignedIn, getToken } = useAuth();
	const clerk = useClerk();

	const tokenGetter = useCallback(
		(opts?: { skipCache?: boolean }) => getToken({ skipCache: opts?.skipCache }),
		[getToken],
	);

	useEffect(() => {
		setTokenGetter(tokenGetter);
	}, [tokenGetter]);

	// Remember the Clerk user id while we still have it. If the multi-account
	// block deletes this user moments later, the sign-in bounce can look up why.
	const clerkUserId = clerk.user?.id;
	useEffect(() => {
		if (clerkUserId) {
			rememberSignupUser(clerkUserId);
		}
	}, [clerkUserId]);

	useClearQueryCacheOnUserChange(queryClient, clerkUserId);
	useWipeCrdtOnUserChange(clerkUserId);

	const email = clerk.user?.primaryEmailAddress?.emailAddress;
	const imageUrl = clerk.user?.imageUrl;

	// `client` is mandatory here: this provider sits ABOVE QueryClientProvider in
	// main.tsx, so the context lookup inside useQuery throws "No QueryClient set"
	// and the whole app renders the error boundary. `enabled` does not save it —
	// useQuery resolves the client before it reads `enabled`.
	// Gated anyway: this renders for signed-OUT visitors too, and an
	// unauthenticated /me call 401s and stalls the sign-in redirect.
	const { data: me } = useMe({ enabled: isLoaded && isSignedIn === true, client: queryClient });

	useIdentifyUserOnAuthChange({
		isLoaded,
		isSignedIn: isSignedIn ?? false,
		id: clerkUserId,
		analyticsId: me?.analytics_id ?? undefined,
		analyticsOptOut: me?.analytics_opt_out,
	});
	const { t } = useT();
	// Every sign-out entry point routes here, so the guard lives here: a repeat
	// tap while Clerk is still signing out is ignored, not queued.
	const signingOut = useRef(false);
	const logout = useCallback(async () => {
		if (signingOut.current) {
			return;
		}
		signingOut.current = true;
		notify.loading(t("Signing out…"), { id: SIGN_OUT_TOAST });
		// Never awaited: the browser holds the Clear-Site-Data reply until its
		// cache wipe ends (minutes on Android), which used to block sign-out.
		clearHttpCache();
		const signedOut = clerk.signOut();
		// Success clears the toast whenever it lands: on time that is the loading
		// toast, after the timeout it is the now-wrong "Could not sign out".
		signedOut.then(
			() => notify.dismiss(SIGN_OUT_TOAST),
			() => undefined,
		);
		let timer: ReturnType<typeof setTimeout> | undefined;
		try {
			// A hung signOut would leave the loading toast up and every later
			// tap ignored until reload: give up, say so, and allow a retry.
			await Promise.race([
				signedOut,
				new Promise((_, reject) => {
					timer = setTimeout(
						() => reject(new Error("clerk.signOut timed out")),
						SIGN_OUT_TIMEOUT_MS,
					);
				}),
			]);
		} catch (err) {
			captureError(err);
			notify.error(t("Could not sign out"), { id: SIGN_OUT_TOAST });
		} finally {
			clearTimeout(timer);
			signingOut.current = false;
		}
	}, [clerk, t]);

	const adapter: AuthAdapter = useMemo(
		() => ({
			isLoaded,
			isSignedIn: isSignedIn ?? false,
			user: isSignedIn && email ? { email, imageUrl } : null,
			getToken: tokenGetter,
			logout,
			hasBuiltInUI: true,
		}),
		[isLoaded, isSignedIn, email, imageUrl, tokenGetter, logout],
	);

	return <AuthContext.Provider value={adapter}>{children}</AuthContext.Provider>;
}

// clerk-js is a script Clerk hot-loads from clerk.engram.page. When it fails
// (blocked, offline, a CDN miss) Clerk sets `status` to "error" and never
// loads, so every auth-gated page waits on a spinner forever (Sentry
// ENGRAM-FRONTEND-A). Show the failure with a way out instead. Clerk's own
// rejection escapes unhandled (a `throw` inside a `.catch` nobody awaits in
// @clerk/shared loadClerkJSScript), so sentry.ts ignores it and this reports
// the failure once, as a handled warning.
function ClerkLoadGate({ children }: { children: React.ReactNode }) {
	const failed = useClerk().status === "error";
	const { t } = useT();

	useEffect(() => {
		if (failed) {
			sentryReady?.then((Sentry) => Sentry?.captureMessage("clerk_js_load_failed", "warning"));
		}
	}, [failed]);

	if (!failed) {
		return children;
	}
	return (
		<AuthPanel className="flex flex-col items-center gap-4 text-center">
			<h1 className={heading}>{t("Couldn't load sign-in")}</h1>
			<p className="text-muted-foreground text-sm">
				{t("The sign-in service didn't load. Check your connection, then reload the page.")}
			</p>
			<Button type="button" onClick={() => window.location.reload()}>
				{t("Reload")}
			</Button>
		</AuthPanel>
	);
}

// Clerk's components follow the rendered app locale. The catalog is a lazy
// chunk per language, so English (undefined) shows until it lands, and stays on
// a failed load. Tagged with its locale so a stale load is never applied.
function useClerkLocalization(): ClerkLocalization | undefined {
	const { renderedLocale } = useT();
	const [loaded, setLoaded] = useState<{ locale: Locale; localization: ClerkLocalization }>();

	useEffect(() => {
		const load = clerkLocalizationLoaders[renderedLocale];
		if (!load) {
			return;
		}
		let current = true;
		load()
			.then((localization) => {
				// undefined: vite:preloadError's preventDefault() resolves the preload to nothing.
				if (current && localization) {
					setLoaded({ locale: renderedLocale, localization });
				}
			})
			.catch(async (error: unknown) => {
				await captureError(error);
			});
		return () => {
			current = false;
		};
	}, [renderedLocale]);

	return loaded?.locale === renderedLocale ? loaded.localization : undefined;
}

// Clerk passes the post-auth redirect target as an ABSOLUTE URL when it crosses
// (or might cross) origins — including the in-origin case after an OAuth
// callback completes. React Router's `navigate("https://app.engram.page/")`
// silently no-ops on absolute URLs (treats it as a path), leaving the user
// stuck on `/sign-in#/?sign_in_force_redirect_url=...` after Google return.
// Strip same-origin targets back to a path so the SPA router actually moves.
// Off-origin URLs pass through untouched for full-page navigation.
export function toRelativeUrl(to: string): string {
	try {
		const u = new URL(to, window.location.origin);
		return u.origin === window.location.origin ? u.pathname + u.search + u.hash : to;
	} catch {
		return to;
	}
}

export default function ClerkAuthProvider({ children }: { children: React.ReactNode }) {
	const { resolved } = useTheme();
	const config = useConfig();
	const clerkPubKey = config.clerkPublishableKey;
	const localization = useClerkLocalization();

	const appearance = useMemo(
		() => ({
			baseTheme: resolved === "dark" ? dark : undefined,
			variables: clerkVariables,
			elements: clerkElements,
		}),
		[resolved],
	);

	if (!clerkPubKey) {
		throw new Error("CLERK_PUBLISHABLE_KEY is required when AUTH_PROVIDER=clerk");
	}

	// /sign-up stays alive for invited users following the email ticket.
	const signUpUrl = ROUTES.SIGN_UP;

	return (
		<ClerkProvider
			publishableKey={clerkPubKey}
			appearance={appearance}
			localization={localization}
			// clerk-telemetry.com is not in our connect-src, so every event is a
			// pair of CSP violations in the console. Turning the collector off beats
			// widening the policy for a third-party host we get nothing back from.
			telemetry={{ disabled: true }}
			signInUrl={ROUTES.SIGN_IN}
			signUpUrl={signUpUrl}
			afterSignOutUrl={ROUTES.SIGN_IN}
			routerPush={(to) => getAppRouter().navigate(toRelativeUrl(to))}
			routerReplace={(to) => getAppRouter().navigate(toRelativeUrl(to), { replace: true })}
		>
			<ClerkLoadGate>
				<ClerkAdapterInner>{children}</ClerkAdapterInner>
			</ClerkLoadGate>
		</ClerkProvider>
	);
}
