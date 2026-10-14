import posthog from "posthog-js";

// Who the browser is capturing for, and whether it may capture at all. With
// init.ts and track.ts, the only files that import posthog-js: swapping the
// vendor means rewriting these three.

// A persisted opt-out belongs to whoever objected, not to this browser: lift it
// for a user who has not objected. Never for a browser sending Do Not Track.
// (GPC never gets this far: init.ts skips posthog entirely, so __loaded is false.)
function resumeCaptureIfAllowed(): void {
	if (posthog.__loaded && posthog.has_opted_out_capturing() && navigator.doNotTrack !== "1") {
		posthog.opt_in_capturing({ captureEventName: false });
	}
}

/** Bind captures to the signed-in user. Id only, never an email. */
export function identifyUser(analyticsId: string): void {
	resumeCaptureIfAllowed();
	posthog.identify(analyticsId);
}

/** The user objected to analytics: send nothing, anonymous included.
 *  posthog-js persists this in localStorage, so it holds from the next page
 *  load onward, before /me has answered. */
export function stopCapture(): void {
	if (posthog.__loaded) {
		posthog.opt_out_capturing();
	}
}

/** Sign-out. `reset()` also clears posthog-js's persisted consent. */
export function forgetUser(): void {
	posthog.reset();
}

/** Person properties for the signed-in user. The caller must skip a user who
 *  objected: on a fresh sign-in this can run before `stopCapture()` has. */
export function setPersonProperties(properties: Record<string, string>): void {
	if (posthog.__loaded && !posthog.has_opted_out_capturing()) {
		posthog.setPersonProperties(properties);
	}
}
