import { analyticsClient } from "./client";

// Who the browser is capturing for, and whether it may capture at all. Every
// call is a no-op until init.ts has loaded posthog-js (see client.ts), which
// on self-host or under GPC is never.

// A persisted opt-out belongs to whoever objected, not to this browser: lift it
// for a user who has not objected. Never for a browser sending Do Not Track.
function resumeCaptureIfAllowed(): void {
	const posthog = analyticsClient();
	if (posthog?.has_opted_out_capturing() && navigator.doNotTrack !== "1") {
		posthog.opt_in_capturing({ captureEventName: false });
	}
}

/** Bind captures to the signed-in user. Id only, never an email. */
export function identifyUser(analyticsId: string): void {
	resumeCaptureIfAllowed();
	analyticsClient()?.identify(analyticsId);
}

/** The user objected to analytics: send nothing, anonymous included.
 *  posthog-js persists this in localStorage, so it holds from the next page
 *  load onward, before /me has answered. */
export function stopCapture(): void {
	analyticsClient()?.opt_out_capturing();
}

/** Sign-out. `reset()` also clears posthog-js's persisted consent. */
export function forgetUser(): void {
	analyticsClient()?.reset();
}

/** Person properties for the signed-in user. The caller must skip a user who
 *  objected: on a fresh sign-in this can run before `stopCapture()` has. */
export function setPersonProperties(properties: Record<string, string>): void {
	const posthog = analyticsClient();
	if (posthog && !posthog.has_opted_out_capturing()) {
		posthog.setPersonProperties(properties);
	}
}
