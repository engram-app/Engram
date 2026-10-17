import { getApiBase, joinApiUrl } from "../api/base";

/** Ask the API origin to answer `Clear-Site-Data: "cache"` so the browser drops
 *  its HTTP cache: `/api/vault/tree` is `private, no-cache` with an ETag, so the
 *  signed-out user's tree otherwise stays on disk. Clerk signs out client-side,
 *  with no request of ours to carry the header. Best-effort: never throws. */
export async function clearHttpCache(): Promise<void> {
	await fetch(joinApiUrl(getApiBase(), "/api/auth/clear-cache"), {
		method: "POST",
		credentials: "include",
	}).catch((err) => console.error("Clear-cache request failed:", err));
}
