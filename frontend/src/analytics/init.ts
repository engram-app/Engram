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
export async function initAnalytics(key: string): Promise<void> {
	if (!key) return;

	// GPC has legal force under CCPA/CPRA and is what our privacy policy
	// promises. posthog's respect_dnt covers the deprecated DNT header only.
	if ((navigator as { globalPrivacyControl?: boolean }).globalPrivacyControl === true) return;

	const { default: posthog } = await import("posthog-js");
	posthog.init(key, {
		api_host: import.meta.env.VITE_POSTHOG_HOST ?? "/ph",
		persistence: "memory",
		person_profiles: "identified_only",
		autocapture: false,
		capture_pageview: false,
		capture_pageleave: false,
		disable_session_recording: true,
		// Honor the browser's DNT signal as belt-and-suspenders.
		respect_dnt: true,
	});
}
