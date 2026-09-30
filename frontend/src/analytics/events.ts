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
	| "mcp_connect_failed"
	| "upgrade_link_clicked"
	| "checklist_action"
	| "vault_source_picked"
	| "plugin_listing_opened";

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
export type CheckoutMethod = (typeof CHECKOUT_METHODS)[number];

// Mirrors billing/plan-cards.tsx's PlanTier. Kept local rather than imported —
// every other enum here is self-contained, and importing from billing would
// be the only cross-domain edge in this file.
export const CHECKOUT_TIERS = ["starter", "pro"] as const;

// Where an "Upgrade" link was clicked. The wizard's tools step and the
// post-wizard checklist both send Free users to /onboard/billing.
export const UPGRADE_SOURCES = ["tools_step", "checklist"] as const;

// Every row the checklist can render: vault, discord, the Obsidian plugin and
// one per selectable tool slug (onboarding-tools.ts). Enumerated because a
// dropped-not-forwarded item is the privacy contract; checklist-widget.test.tsx
// fails if a doc-backed row is missing here.
export const CHECKLIST_ITEMS = [
	"vault",
	"join_discord",
	"install_obsidian_plugin",
	"claude",
	"chatgpt",
	"grok",
	"mistral",
	"open_webui",
	"lobechat",
	"claude_code",
	"cursor",
	"devin",
	"windsurf",
	"cline",
	"continue",
	"opencode",
	"github_copilot",
	"antigravity",
	"other_mcp",
] as const;

export const CHECKLIST_ACTIONS = ["guide_opened", "dismissed"] as const;

// The two cards on the wizard's vault step.
export const VAULT_SOURCES = ["obsidian", "fresh"] as const;

export const MCP_CLIENTS = ["chatgpt", "claude", "cursor", "other"] as const;

// Mirrors Engram.Onboarding.gate_missing/1's string list ("terms",
// "subscription", "profile", "vault") — a DIFFERENT vocabulary from
// OnboardingStep ("agreement", "billing", "tools", "vault", "done"). Only
// "vault" happens to spell the same in both; the other three don't line up
// (terms↔agreement, subscription↔billing, profile↔tools), so this cannot
// reuse the "step" kind.
export const GATE_REASONS = ["terms", "subscription", "profile", "vault"] as const;

// Error codes, deliberately enumerated. An unrecognised code is dropped rather
// than forwarded, because "error detail" is where free text hides.
export const ERROR_CODES = [
	"onboarding_required",
	"gate_closed",
	"not_found",
	"rate_limited",
	"network",
	"timeout",
	// Paddle checkout attempt failed (declined card, insufficient funds, …).
	// The specific decline reason is processor-generated text and must never
	// be forwarded — this is one deliberate bucket, not an attempt to mirror
	// Paddle's own granular error codes.
	"payment_declined",
	// A connection attempt (plugin device-link, MCP OAuth) hit a plan cap
	// (LimitExceededError) rather than an ordinary failure.
	"limit_exceeded",
	"unknown",
] as const;

/** The value kinds `track()` knows how to validate. Every property any event
 *  declares must be one of these — there is no "string" or "any" kind, on
 *  purpose. See track.ts's `isKind`. */
export type PropKind =
	| "uuid"
	| "step"
	| "checkout_method"
	| "tier"
	| "mcp_client"
	| "upgrade_source"
	| "checklist_item"
	| "checklist_action"
	| "vault_source"
	| "error_code"
	| "gate_reasons"
	| "boolean"
	| "number";

/** Per-event property allowlist: which keys an event may carry, and what kind
 *  each key's value must be. This is the actual enforcement surface — `track()`
 *  rejects any key not listed here for the given event, whatever its value.
 *  `Record<EngramEvent, ...>` is exhaustive on purpose: adding an event to the
 *  union without a schema entry here is a type error, not a silent bypass. */
export const EVENT_SCHEMAS: Record<EngramEvent, Record<string, PropKind>> = {
	onboarding_step_viewed: { step: "step" },
	onboarding_step_completed: { step: "step", vault_id: "uuid", duration_ms: "number" },
	// Corrected from the first-cut `{ step, reason: error_code }` — the actual
	// 403 body (RequireOnboarding) carries `missing` (a list of GATE_REASONS)
	// and `next_step` (an OnboardingStep), never a single "reason".
	onboarding_blocked: { missing: "gate_reasons", next_step: "step" },
	plugin_connect_started: { vault_id: "uuid" },
	plugin_connect_succeeded: { vault_id: "uuid", duration_ms: "number" },
	plugin_connect_failed: { vault_id: "uuid", reason: "error_code" },
	vault_first_sync_completed: { vault_id: "uuid", note_count: "number", duration_ms: "number" },
	checkout_opened: { method: "checkout_method", tier: "tier" },
	checkout_stalled: { method: "checkout_method", reason: "error_code" },
	checkout_completed: { method: "checkout_method" },
	checkout_abandoned: { method: "checkout_method", reason: "error_code" },
	mcp_connect_attempted: { client: "mcp_client" },
	mcp_connect_succeeded: { client: "mcp_client" },
	mcp_connect_failed: { client: "mcp_client", reason: "error_code" },
	upgrade_link_clicked: { source: "upgrade_source" },
	checklist_action: { item: "checklist_item", action: "checklist_action" },
	vault_source_picked: { source: "vault_source" },
	// No properties: the click itself is the signal.
	plugin_listing_opened: {},
};
