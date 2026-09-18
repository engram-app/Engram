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
