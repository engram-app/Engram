import posthog from "posthog-js";
import { isMember } from "../lib/is-member";
import { captureError } from "../sentry";
import {
	CHECKOUT_METHODS,
	CHECKOUT_TIERS,
	type EngramEvent,
	ERROR_CODES,
	EVENT_SCHEMAS,
	GATE_REASONS,
	MCP_CLIENTS,
	ONBOARDING_STEPS,
	type PropKind,
} from "./events";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** A value is allowed only if it both matches its declared kind AND sits under
 *  a key the event's schema actually declares — see EVENT_SCHEMAS. Checking
 *  the value alone (a UUID regex, an enum-member check) is not enough: a note
 *  titled "done" is a valid `step` value, so the key has to gate FIRST. */
function isKind(kind: PropKind, value: unknown): boolean {
	switch (kind) {
		case "uuid":
			return typeof value === "string" && UUID.test(value);
		case "step":
			return isMember(ONBOARDING_STEPS, value);
		case "checkout_method":
			return isMember(CHECKOUT_METHODS, value);
		case "tier":
			return isMember(CHECKOUT_TIERS, value);
		case "mcp_client":
			return isMember(MCP_CLIENTS, value);
		case "error_code":
			return isMember(ERROR_CODES, value);
		case "gate_reasons":
			return Array.isArray(value) && value.every((v) => isMember(GATE_REASONS, v));
		case "boolean":
			return typeof value === "boolean";
		case "number":
			return typeof value === "number" && Number.isFinite(value);
		default:
			// Unreachable under the exhaustive PropKind type, but a kind smuggled
			// in via `as PropKind` gets no free pass at runtime either.
			return false;
	}
}

/** Report a rejected event to Sentry so enum drift shows up somewhere instead
 *  of silently killing funnel data. The event name and the offending property
 *  KEY only — never the value, which is exactly the user content this module
 *  exists to keep out. Fire-and-forget: captureError already swallows its own
 *  failures and must never block or throw into the calling analytics path. */
function reportViolation(message: string): void {
	console.warn(message);
	captureError(new Error(message));

	// Deliberately NEVER thrown — not synchronously, and not deferred either.
	//
	// It used to throw when `import.meta.env.DEV`. The e2e suite runs
	// `bun run dev`, so DEV was true in CI, and a single rejected property was
	// caught by React's error boundary and replaced the entire page with
	// "Something went wrong" — the analytics guard taking down the product it
	// exists to measure. Deferring the throw via queueMicrotask dodges the
	// boundary but still registers as an unhandled error, which vitest fails
	// the run on and Playwright's pageerror handler would catch.
	//
	// console.warn + Sentry is the whole reporting path. A dropped event is a
	// data gap; a thrown one is an outage.
}

export function track(event: EngramEvent, props: Record<string, unknown> = {}): void {
	const schema = EVENT_SCHEMAS[event];
	if (!schema) {
		// Unreachable under the exhaustive EVENT_SCHEMAS type, but an event
		// smuggled in via `as EngramEvent` gets no free pass at runtime either.
		reportViolation(`analytics: no schema declared for event "${event}"`);
		return;
	}

	for (const [key, value] of Object.entries(props)) {
		const kind = schema[key];
		if (kind !== undefined && isKind(kind, value)) {
			continue;
		}

		reportViolation(`analytics: property "${key}" on "${event}" is not an allowed value`);
		return; // Drop the whole event. A partial event is a silent lie.
	}

	posthog.capture(event, props);
}
