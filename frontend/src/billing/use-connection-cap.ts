import { useBillingStatus } from "../api/queries";

export interface ConnectionCapState {
	isLoading: boolean;
	atCap: boolean;
	limit: number | null;
	current: number;
	// Hours remaining on the Free-tier device-swap cooldown after a recent
	// device revoke; `null` when no cooldown is in effect. /link uses this
	// to render a cooldown-specific banner + disable Authorize so the user
	// doesn't trip the 402 mid-flow.
	swapCooldownHours: number | null;
}

/**
 * Reads the cap shape for a connection kind from the bundled `/billing/status`
 * response. Returns `atCap` true only when there's a positive integer limit
 * AND the user is at or above it — a `null` (unlimited) limit is never at cap.
 *
 * Used by the proactive cap UI on /link and /oauth/consent to swap the normal
 * flow for the disconnect panel without an extra fetch.
 */
export function useConnectionCap(kind: "mcp" | "obsidian"): ConnectionCapState {
	const { data: billing } = useBillingStatus();
	if (!billing) {
		return {
			isLoading: true,
			atCap: false,
			limit: null,
			current: 0,
			swapCooldownHours: null,
		};
	}

	// MCP connections are uncapped on every tier (#1974): never at cap.
	const limit = kind === "obsidian" ? billing.caps.obsidian_connections : null;
	const current = kind === "obsidian" ? (billing.current_connections?.obsidian ?? 0) : 0;
	const atCap = typeof limit === "number" && limit > 0 && current >= limit;

	return {
		isLoading: false,
		atCap,
		limit,
		current,
		swapCooldownHours: billing.device_swap_cooldown_remaining_hours ?? null,
	};
}
