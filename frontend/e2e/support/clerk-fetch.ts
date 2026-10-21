/**
 * fetch() against Clerk's Backend API, riding out its rate limit.
 *
 * Clerk's test instance is shared by every concurrent CI run, and a 429
 * RESOLVES as a non-ok Response rather than throwing. Callers that threw on
 * `!resp.ok` turned that transient into a failed spec (#2105). A 429 is
 * retried, waiting what `Retry-After` asks (seconds or an HTTP date), else
 * exponential backoff from 500 ms. Any other status returns at once. Once
 * the budget is spent the last 429 is returned, so the caller's own error
 * still names the status.
 */
interface ClerkFetchOptions {
	budgetMs?: number;
	fetchImpl?: typeof fetch;
	sleep?: (ms: number) => Promise<void>;
}

const wait = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

function retryAfterMs(header: string | null): number | null {
	if (!header) {
		return null;
	}
	const seconds = Number(header);
	if (Number.isFinite(seconds)) {
		return Math.max(0, seconds * 1000);
	}
	const at = Date.parse(header);
	return Number.isNaN(at) ? null : Math.max(0, at - Date.now());
}

export async function clerkFetch(
	url: string,
	init: RequestInit = {},
	{ budgetMs = 60_000, fetchImpl = fetch, sleep = wait }: ClerkFetchOptions = {},
): Promise<Response> {
	const deadline = Date.now() + budgetMs;
	let backoff = 500;

	for (;;) {
		const resp = await fetchImpl(url, init);
		if (resp.status !== 429) {
			return resp;
		}
		const pause = retryAfterMs(resp.headers.get("retry-after")) ?? backoff;
		if (Date.now() + pause > deadline) {
			return resp;
		}
		console.warn(`clerk 429 on ${init.method ?? "GET"} ${url}, retrying in ${pause}ms`);
		await resp.body?.cancel();
		await sleep(pause);
		backoff = Math.min(backoff * 2, 8000);
	}
}
