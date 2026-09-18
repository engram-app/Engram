// PostHog — product analytics. Cookieless by `persistence: 'memory'` per
// [[reference_cookie_audit_2026_05_24]] so the no-banner launch posture
// holds. Autocapture is OFF — explicit events only is the single biggest
// cost lever on the free tier, per [[project_observability_stack_plan]].
// The identify call happens in the Clerk auth provider as soon as the user
// resolves, NOT here — firing it pre-auth would burn a permanent anonymous
// distinct_id.
//
// Own module (mirrors sentry.ts) so main.tsx's inline call site stays a
// one-liner and this is importable/testable without pulling in main.tsx's
// module-scope createRoot(...).render(...) side effect.
// posthog-js merges its own page-info properties ($current_url, $pathname,
// $host, $referrer, $referring_domain, $initial_current_url,
// $session_entry_url, ...) into EVERY capture(), regardless of
// autocapture/capture_pageview settings — vault routes are /v/:slug where
// slug embeds the vault name in plaintext, so this would leak it. Match on
// shape (key name or URL-looking value), not an exact-name list: posthog-js
// can add a differently-named URL property in a future version and a
// fixed-name denylist would silently stop covering it.
function isUrlLike(key: string, value: unknown): boolean {
	if (/url|referr|pathname|host/i.test(key)) return true;
	return typeof value === "string" && /^https?:\/\//i.test(value);
}

export async function initAnalytics(key: string): Promise<void> {
	if (!key) return;

	// GPC has legal force under CCPA/CPRA and is what our privacy policy
	// promises. posthog's respect_dnt covers the deprecated DNT header only.
	if ((navigator as { globalPrivacyControl?: boolean }).globalPrivacyControl === true) return;

	const { default: posthog } = await import("posthog-js");
	posthog.init(key, {
		api_host: import.meta.env.VITE_POSTHOG_HOST || "/ph",
		persistence: "memory",
		person_profiles: "identified_only",
		autocapture: false,
		capture_pageview: false,
		capture_pageleave: false,
		disable_session_recording: true,
		// Honor the browser's DNT signal as belt-and-suspenders.
		respect_dnt: true,
		// Fail-closed strip of any URL-bearing property the SDK attaches on
		// its own — see isUrlLike above. Every funnel event already carries
		// step/vault_id/client explicitly, so nothing of value is lost.
		sanitize_properties: (properties, _event) => {
			const clean: Record<string, unknown> = {};
			for (const [propKey, propValue] of Object.entries(properties)) {
				if (isUrlLike(propKey, propValue)) continue;
				clean[propKey] = propValue;
			}
			return clean;
		},
	});
}
