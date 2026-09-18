/** Every event this app may emit. Adding one here is a deliberate act —
 *  see the property rules in track.ts before you do. */
export type EngramEvent =
	| "onboarding_step_viewed"
	| "onboarding_step_completed"
	| "onboarding_blocked"
	| "plugin_connect_started"
	| "plugin_connect_succeeded"
	| "plugin_connect_failed"
	| "vault_first_sync_completed"
	| "checkout_opened"
	| "checkout_stalled"
	| "checkout_completed"
	| "checkout_abandoned"
	| "mcp_connect_attempted"
	| "mcp_connect_succeeded"
	| "mcp_connect_failed";

/** Mirrors Engram.Onboarding.gate/2's next_step. One state machine, not two. */
export type OnboardingStep = "agreement" | "billing" | "tools" | "vault" | "done";

export const ONBOARDING_STEPS: readonly OnboardingStep[] = [
	"agreement",
	"billing",
	"tools",
	"vault",
	"done",
] as const;

export const CHECKOUT_METHODS = ["card", "apple_pay", "google_pay", "paypal", "unknown"] as const;

export const MCP_CLIENTS = ["chatgpt", "claude", "cursor", "other"] as const;

// Error codes, deliberately enumerated. An unrecognised code is dropped rather
// than forwarded, because "error detail" is where free text hides.
export const ERROR_CODES = [
	"onboarding_required",
	"gate_closed",
	"not_found",
	"rate_limited",
	"network",
	"timeout",
	"unknown",
] as const;

/** The value kinds `track()` knows how to validate. Every property any event
 *  declares must be one of these — there is no "string" or "any" kind, on
 *  purpose. See track.ts's `isKind`. */
export type PropKind = "uuid" | "step" | "checkout_method" | "mcp_client" | "error_code" | "boolean" | "number";

/** Per-event property allowlist: which keys an event may carry, and what kind
 *  each key's value must be. This is the actual enforcement surface — `track()`
 *  rejects any key not listed here for the given event, whatever its value.
 *  `Record<EngramEvent, ...>` is exhaustive on purpose: adding an event to the
 *  union without a schema entry here is a type error, not a silent bypass. */
export const EVENT_SCHEMAS: Record<EngramEvent, Record<string, PropKind>> = {
	onboarding_step_viewed: { step: "step", vault_id: "uuid", is_retry: "boolean", duration_ms: "number" },
	onboarding_step_completed: { step: "step", vault_id: "uuid", duration_ms: "number" },
	onboarding_blocked: { step: "step", reason: "error_code" },
	plugin_connect_started: { vault_id: "uuid" },
	plugin_connect_succeeded: { vault_id: "uuid", duration_ms: "number" },
	plugin_connect_failed: { vault_id: "uuid", reason: "error_code" },
	vault_first_sync_completed: { vault_id: "uuid", note_count: "number", duration_ms: "number" },
	checkout_opened: { method: "checkout_method" },
	checkout_stalled: { method: "checkout_method", reason: "error_code" },
	checkout_completed: { method: "checkout_method" },
	checkout_abandoned: { method: "checkout_method", reason: "error_code" },
	mcp_connect_attempted: { client: "mcp_client" },
	mcp_connect_succeeded: { client: "mcp_client" },
	mcp_connect_failed: { client: "mcp_client", reason: "error_code" },
};
