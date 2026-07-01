import { ROUTES } from "../routes";

// Reject return_to values that aren't a SPA-relative path. Prevents
// open-redirect via /sign-in?return_to=https://attacker/...
//
// `//evil` is protocol-relative. Some URL parsers also treat `\` like
// `/`, so `/\evil.com` can degrade to `//evil.com`. Reject both shapes.
export function safeReturnTo(raw: string | null): string {
	if (!raw) {
		return ROUTES.HOME;
	}
	if (!raw.startsWith("/")) {
		return ROUTES.HOME;
	}
	if (raw.startsWith("//")) {
		return ROUTES.HOME;
	}
	if (raw.startsWith("/\\")) {
		return ROUTES.HOME;
	}
	return raw;
}
