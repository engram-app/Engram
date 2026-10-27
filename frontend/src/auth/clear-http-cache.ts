import { getApiBase, joinApiUrl } from "../api/base";

/** Fire a credentialed POST at an endpoint that answers `Clear-Site-Data:
 *  "cache"`, and do NOT wait for it. The browser holds that response open
 *  until it has wiped its HTTP cache: seconds on desktop, minutes on Android
 *  Chrome, so awaiting it blocked sign-out entirely. `keepalive` lets the
 *  request outlive the page if the user closes the tab or a hard navigation
 *  follows. Best-effort: never throws, never blocks. */
export function postClearingCache(path: string): void {
	void fetch(joinApiUrl(getApiBase(), path), {
		method: "POST",
		credentials: "include",
		keepalive: true,
	}).catch((err) => console.error(`${path} request failed:`, err));
}

/** Ask the API origin to clear the browser's HTTP cache: `/api/vault/tree` is
 *  `private, no-cache` with an ETag, so the signed-out user's tree otherwise
 *  stays on disk. Clerk signs out client-side, with no request of ours to
 *  carry the header. */
export function clearHttpCache(): void {
	postClearingCache("/api/auth/clear-cache");
}
