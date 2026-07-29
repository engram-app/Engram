// Settings is addressed by hash, not path, so the dialog overlays whatever page
// you were on and closing can simply strip the hash instead of inventing a
// destination (the old `/settings/*` path route hardcoded `navigate("/")`,
// which dumped you on the dashboard even if you came from a note).
const PREFIX = "#settings";

const KNOWN: readonly string[] = ["account", "vaults", "connections", "billing", "admin"];

// Carried over from the old `/settings/api-keys` route alias so existing links
// and bookmarks keep landing on Connections.
const ALIASES: Record<string, string> = { "api-keys": "connections" };

export type SettingsSectionKey = "account" | "vaults" | "connections" | "billing" | "admin";

export function isSettingsHash(hash: string): boolean {
	return hash === PREFIX || hash.startsWith(`${PREFIX}/`);
}

export function parseSettingsHash(hash: string): SettingsSectionKey | null {
	if (!isSettingsHash(hash)) {
		return null;
	}
	const raw = hash.slice(PREFIX.length).replace(/^\//, "");
	if (raw === "") {
		return "account";
	}
	const resolved = ALIASES[raw] ?? raw;
	// An unknown section is a typo or a stale link, not a reason to render
	// nothing: open on Account rather than an empty dialog body.
	return KNOWN.includes(resolved) ? (resolved as SettingsSectionKey) : "account";
}

export function settingsHash(section: SettingsSectionKey): string {
	return `${PREFIX}/${section}`;
}

/**
 * Build a react-router `To` for opening settings that PRESERVES the current
 * query string. React Router's resolvePath inherits `pathname` from the current
 * location but NOT `search` (it defaults to ""), so a bare hash target silently
 * drops the query. That breaks any page whose state lives in the URL, most
 * severely /oauth/consent, which reads its params via useSearchParams and errors
 * out the moment they vanish. Callers pass `location.search` from useLocation().
 */
export function settingsTo(section: SettingsSectionKey, search: string) {
	return { search, hash: settingsHash(section) };
}
