import { ClerkProvider, useAuth, useClerk } from "@clerk/react";
import { dark } from "@clerk/themes";
import posthog from "posthog-js";
import { useCallback, useEffect, useMemo } from "react";
import { setTokenGetter } from "../api/client";
import { queryClient } from "../api/query-client";
import { useConfig } from "../config-context";
import { getAppRouter } from "../router";
import { ROUTES } from "../routes";
import { useTheme } from "../theme/theme-provider";
import { type AuthAdapter, AuthContext } from "./auth-context";
import { rememberSignupUser } from "./signup-rejection";
import { useClearQueryCacheOnUserChange } from "./use-clear-query-cache-on-user-change";

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

function ClerkAdapterInner({ children }: { children: React.ReactNode }) {
	const { isLoaded, isSignedIn, getToken } = useAuth();
	const clerk = useClerk();

	const tokenGetter = useCallback(() => getToken(), [getToken]);

	useEffect(() => {
		setTokenGetter(tokenGetter);
	}, [tokenGetter]);

	// Remember the Clerk user id while we still have it. If the multi-account
	// block deletes this user moments later, the sign-in bounce can look up why.
	const clerkUserId = clerk.user?.id;
	useEffect(() => {
		if (clerkUserId) rememberSignupUser(clerkUserId);
	}, [clerkUserId]);

	useClearQueryCacheOnUserChange(queryClient, clerkUserId);

	const email = clerk.user?.primaryEmailAddress?.emailAddress;
	const imageUrl = clerk.user?.imageUrl;

	// PostHog identify on auth resolved, reset on sign-out. Firing
	// `identify` is what binds the anonymous device's prior events to
	// the real user — missing this step is the single most-common
	// PostHog integration bug per [[project_observability_stack_plan]].
	// No-op when PostHog isn't initialized (VITE_POSTHOG_KEY unset).
	useEffect(() => {
		if (!isLoaded) return;
		if (isSignedIn && clerkUserId) {
			posthog.identify(clerkUserId, email ? { email } : undefined);
		} else if (!isSignedIn) {
			posthog.reset();
		}
	}, [isLoaded, isSignedIn, clerkUserId, email]);
	const adapter: AuthAdapter = useMemo(
		() => ({
			isLoaded,
			isSignedIn: isSignedIn ?? false,
			user: isSignedIn && email ? { email, imageUrl } : null,
			getToken: tokenGetter,
			logout: async () => {
				await clerk.signOut();
			},
			hasBuiltInUI: true,
		}),
		[isLoaded, isSignedIn, clerk, email, imageUrl, tokenGetter],
	);

	return <AuthContext.Provider value={adapter}>{children}</AuthContext.Provider>;
}

export default function ClerkAuthProvider({ children }: { children: React.ReactNode }) {
	const { resolved } = useTheme();
	const config = useConfig();
	const clerkPubKey = config.clerkPublishableKey;

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

	// Waitlist mode (Dashboard → Restrictions → Waitlist): point Clerk's
	// "sign up" CTAs at /waitlist so non-approved users land on the join
	// form instead of <SignUp />'s "you need to join the waitlist" message.
	// /sign-up stays alive for invited users following the email ticket.
	const signUpUrl = config.clerkWaitlistMode ? ROUTES.WAITLIST : ROUTES.SIGN_UP;
	const waitlistUrl = config.clerkWaitlistMode ? ROUTES.WAITLIST : undefined;

	return (
		<ClerkProvider
			publishableKey={clerkPubKey}
			appearance={appearance}
			signInUrl={ROUTES.SIGN_IN}
			signUpUrl={signUpUrl}
			waitlistUrl={waitlistUrl}
			afterSignOutUrl={ROUTES.SIGN_IN}
			routerPush={(to) => getAppRouter().navigate(toRelativeUrl(to))}
			routerReplace={(to) => getAppRouter().navigate(toRelativeUrl(to), { replace: true })}
		>
			<ClerkAdapterInner>{children}</ClerkAdapterInner>
		</ClerkProvider>
	);
}
