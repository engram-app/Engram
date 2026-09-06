import posthog from "posthog-js";
import { useEffect } from "react";
import { setSentryUser } from "../sentry";

/** Bind the authenticated user to both telemetry sinks, and clear both on
 *  sign-out.
 *
 *  Firing PostHog's `identify` is what binds the anonymous device's prior
 *  events to the real user — missing it is the single most-common PostHog
 *  integration bug per [[project_observability_stack_plan]].
 *
 *  Sentry was the half that got missed: the SPA identified to PostHog and never
 *  to Sentry, so every Sentry issue read `userCount: 0` and "one device
 *  reconnecting in a loop" was indistinguishable from "every user is broken".
 *  They live in ONE hook so the next sink added here cannot quietly acquire the
 *  same gap — an anonymous crash stream looks healthy right up until it isn't.
 *
 *  Both calls no-op when their SDK is unconfigured (`VITE_POSTHOG_KEY` /
 *  `VITE_SENTRY_DSN` unset), which is the self-host shape. */
export function useIdentifyUserOnAuthChange({
	isLoaded,
	isSignedIn,
	id,
	email,
}: {
	isLoaded: boolean;
	isSignedIn: boolean;
	id?: string;
	email?: string;
}): void {
	useEffect(() => {
		// Clerk reports isSignedIn:false while still resolving; acting on that
		// would reset the user on every page load.
		if (!isLoaded) {
			return;
		}
		if (isSignedIn && id) {
			posthog.identify(id, email ? { email } : undefined);
			// Id only — never email. See setSentryUser, which never rejects.
			setSentryUser(id);
		} else if (!isSignedIn) {
			posthog.reset();
			setSentryUser(null);
		}
	}, [isLoaded, isSignedIn, id, email]);
}
