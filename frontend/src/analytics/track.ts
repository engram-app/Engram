import posthog from "posthog-js";
import { captureError } from "../sentry";
import {
	CHECKOUT_METHODS,
	ERROR_CODES,
	type EngramEvent,
	EVENT_SCHEMAS,
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
			return typeof value === "string" && (ONBOARDING_STEPS as readonly string[]).includes(value);
		case "checkout_method":
			return typeof value === "string" && (CHECKOUT_METHODS as readonly string[]).includes(value);
		case "mcp_client":
			return typeof value === "string" && (MCP_CLIENTS as readonly string[]).includes(value);
		case "error_code":
			return typeof value === "string" && (ERROR_CODES as readonly string[]).includes(value);
		case "boolean":
			return typeof value === "boolean";
		case "number":
			return typeof value === "number" && Number.isFinite(value);
	}
}

/** Report a rejected event to Sentry so enum drift shows up somewhere instead
 *  of silently killing funnel data. The event name and the offending property
 *  KEY only — never the value, which is exactly the user content this module
 *  exists to keep out. Fire-and-forget: captureError already swallows its own
 *  failures and must never block or throw into the calling analytics path. */
function reportViolation(message: string): void {
	console.warn(message);
	void captureError(new Error(message));
}

export function track(event: EngramEvent, props: Record<string, unknown> = {}): void {
	const schema = EVENT_SCHEMAS[event];
	if (!schema) {
		// Unreachable under the exhaustive EVENT_SCHEMAS type, but an event
		// smuggled in via `as EngramEvent` gets no free pass at runtime either.
		const message = `analytics: no schema declared for event "${event}"`;
		if (import.meta.env.DEV) throw new Error(message);
		reportViolation(message);
		return;
	}

	for (const [key, value] of Object.entries(props)) {
		const kind = schema[key];
		if (kind !== undefined && isKind(kind, value)) continue;

		const message = `analytics: property "${key}" on "${event}" is not an allowed value`;
		if (import.meta.env.DEV) throw new Error(message);
		reportViolation(message);
		return; // Drop the whole event in prod. A partial event is a silent lie.
	}

	posthog.capture(event, props);
}
