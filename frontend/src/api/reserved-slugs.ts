// Mirror of @reserved_slugs in lib/engram/vaults/vault.ex. Duplicated because
// the check spans two languages; the backend changeset is authoritative, and
// this list currently has no runtime consumer in the SPA (the vault create
// form has no slug field) - it exists as the cross-language mirror of the
// Elixir list. Keep both lists identical:
//   - Frontend-shadowed (sign-in..settings): React Router ranks static
//     segments above `/:slug`, so these are simply unreachable by URL.
//   - Backend-denied (api..socket): Task 7's Phoenix deny-list 404s these
//     prefixes before the SPA ever loads.
//   - Backend-forwarded (metrics): a bearer-auth-gated `forward` mounted
//     ahead of the vault route 401s these before the SPA ever loads.
export const RESERVED_SLUGS: readonly string[] = [
	"sign-in",
	"sign-up",
	"waitlist",
	"link",
	"oauth",
	"onboard",
	"reset-password",
	"note",
	"search",
	"billing",
	"settings",
	"api",
	"webhooks",
	".well-known",
	"assets",
	"email",
	"socket",
	"metrics",
];

export function isReservedSlug(slug: string): boolean {
	return RESERVED_SLUGS.includes(slug.trim().toLowerCase());
}
