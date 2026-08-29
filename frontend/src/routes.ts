// SPA route constants. Single source of truth for paths referenced by
// the router, AuthGuard redirects, Clerk's sign-in/up URLs, and any
// inter-page links. Keeps `/sign-in` from drifting in one place and
// silently breaking redirects in another.
export const ROUTES = {
	HOME: "/",
	SIGN_IN: "/sign-in",
	SIGN_UP: "/sign-up",
	WAITLIST: "/waitlist",
	DEVICE_LINK: "/link",
	RESET_PASSWORD: "/reset-password",
	OAUTH_CONSENT: "/oauth/consent",
} as const;

// Every vault-scoped URL sits under this one segment. Vault slugs are
// user-derived, so while they lived at the root ANY new top-level route (or
// Plug.Static mount, or Phoenix scope) could shadow a vault named after it.
// That needed a hand-maintained reserved-slug list mirrored across Elixir and
// TS; both are gone. Nothing dynamic sits at the root now, so the collision
// class cannot come back.
export const VAULT_PREFIX = "/v";

/** Builds a vault-scoped path: `/v/:slug`, or `/v/:slug/:itemId` with an id. */
export function vaultPath(slug: string, itemId?: string): string {
	return itemId ? `${VAULT_PREFIX}/${slug}/${itemId}` : `${VAULT_PREFIX}/${slug}`;
}
