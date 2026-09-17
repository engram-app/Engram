import { ROUTES } from "../routes";

// Any origin we do not serve. Resolving against a FIXED base rather than
// `window.location.origin` keeps this pure (no DOM, deterministic in tests);
// an absolute URL naming our own host was already rejected before and still is.
const SAME_ORIGIN_BASE = "https://engram.invalid";

/**
 * Reduce a caller-supplied `return_to` to a destination on our own origin.
 *
 * `return_to` is handed to Clerk as `forceRedirectUrl` and to `navigate()` as a
 * raw string; both end at `window.location.assign` for anything off-origin. So
 * this is the open-redirect boundary for every auth surface — a victim would
 * complete a real signup on the real domain and be handed to the attacker.
 *
 * Resolve-and-compare, NOT a prefix denylist. The denylist this replaced
 * rejected `//evil` and `/\evil` but let `/\t/evil.com` through, because WHATWG
 * URL parsing strips tab/CR/LF BEFORE parsing: the raw string starts with a
 * single `/` and passes every prefix test, then degrades to `//evil.com` the
 * moment anything constructs a URL from it. Handing the string to the same
 * parser the browser will use is the only check that sees what it sees.
 */
export function safeReturnTo(raw: string | null): string {
	if (!raw) {
		return ROUTES.HOME;
	}

	let url: URL;
	try {
		url = new URL(raw, SAME_ORIGIN_BASE);
	} catch {
		return ROUTES.HOME;
	}

	// Covers absolute URLs, scheme-relative `//host`, the backslash and
	// whitespace-smuggled variants that degrade to one, and opaque schemes
	// like `javascript:` / `data:` (whose origin serializes to "null").
	if (url.origin !== SAME_ORIGIN_BASE) {
		return ROUTES.HOME;
	}

	return url.pathname + url.search + url.hash;
}
