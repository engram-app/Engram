import type { PostHog } from "posthog-js";

// The loaded posthog-js instance, or null until init.ts has imported and
// initialised it (and forever on self-host or under GPC, where it never does).
// Callers reach PostHog only through here, with type-only imports: a single
// static `import posthog from "posthog-js"` anywhere pulls its ~300 KB into the
// entry bundle and defeats init.ts's lazy import.
let client: PostHog | null = null;

// Work waiting for the client: a once-per-device report must not be marked
// sent while nothing can send it. Never runs under GPC or on self-host.
const waiting: Array<() => void> = [];

export function setAnalyticsClient(next: PostHog | null): void {
	client = next;
	if (client) {
		for (const run of waiting.splice(0)) {
			run();
		}
	}
}

/** Run `fn` once analytics can send: now if it is loaded, else when it loads. */
export function whenAnalyticsReady(fn: () => void): void {
	if (client) {
		fn();
	} else {
		waiting.push(fn);
	}
}

export function analyticsClient(): PostHog | null {
	return client;
}
