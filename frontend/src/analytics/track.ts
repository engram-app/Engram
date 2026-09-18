import posthog from "posthog-js";
import { CHECKOUT_METHODS, type EngramEvent, MCP_CLIENTS, ONBOARDING_STEPS } from "./events";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const ENUM_VALUES: ReadonlySet<string> = new Set([
	...ONBOARDING_STEPS,
	...CHECKOUT_METHODS,
	...MCP_CLIENTS,
	// Error codes, deliberately enumerated. An unrecognised code is dropped
	// rather than forwarded, because "error detail" is where free text hides.
	"onboarding_required",
	"gate_closed",
	"not_found",
	"rate_limited",
	"network",
	"timeout",
	"unknown",
]);

/** A property value is allowed ONLY if it is provably not user content.
 *
 *  This product stores people's private notes. The failure mode we are
 *  designing against is not malice, it is a future `{ title }` added to an
 *  event in a hurry. An allowlist fails closed; a denylist would not. */
function isAllowed(value: unknown): boolean {
	if (typeof value === "boolean") return true;
	if (typeof value === "number") return Number.isFinite(value);
	if (Array.isArray(value)) return value.every(isAllowed);
	if (typeof value === "string") return UUID.test(value) || ENUM_VALUES.has(value);
	return false;
}

export function track(event: EngramEvent, props: Record<string, unknown> = {}): void {
	for (const [key, value] of Object.entries(props)) {
		if (isAllowed(value)) continue;

		const message = `analytics: property "${key}" on "${event}" is not an allowed value type`;
		if (import.meta.env.DEV) throw new Error(message);
		console.warn(message);
		return; // Drop the whole event in prod. A partial event is a silent lie.
	}

	posthog.capture(event, props);
}
