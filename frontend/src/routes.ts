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

// The nullable-slug policy, owned in ONE place. Seven call sites used to
// inline `slug ? vaultPath(slug, id) : `/note/${id}`` (and two of them
// answered it differently, with `"/"`), which is the same
// hand-mirrored-in-many-places shape the reserved-slug list was deleted for.
// Retiring the legacy `/note/:id` redirect is now a one-line edit here
// instead of a grep across five files that would also miss the other two.
//
// `vaultPath` deliberately keeps its non-nullable `slug: string` so callers
// that genuinely have a slug still get a type error if they pass undefined.

/** Where a note lives. Falls back to the legacy `/note/:id` redirect, which
 *  resolves the vault server-side, when the caller has no slug yet. */
export function noteHref(slug: string | null | undefined, noteId: string): string {
	return slug ? vaultPath(slug, noteId) : `/note/${noteId}`;
}

/** A vault's root. Falls back to `/`, which picks a vault via VaultRedirect. */
export function vaultRootHref(slug: string | null | undefined): string {
	return slug ? vaultPath(slug) : ROUTES.HOME;
}
