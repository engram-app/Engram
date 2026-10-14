import type { PostHog } from "posthog-js";

// The loaded posthog-js instance, or null until init.ts has imported and
// initialised it (and forever on self-host or under GPC, where it never does).
// Callers reach PostHog only through here, with type-only imports: a single
// static `import posthog from "posthog-js"` anywhere pulls its ~300 KB into the
// entry bundle and defeats init.ts's lazy import.
let client: PostHog | null = null;

export function setAnalyticsClient(next: PostHog | null): void {
	client = next;
}

export function analyticsClient(): PostHog | null {
	return client;
}
