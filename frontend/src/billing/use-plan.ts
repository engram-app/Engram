import type { MsgKey } from "@/i18n/ui-text";
import { useBillingStatus } from "../api/queries";
import { useConfig } from "../config-context";
import { isMember } from "../lib/is-member";
import { FREE_TIER, PLAN_CATALOG } from "./plan-cards";

export interface CurrentPlan {
	name: MsgKey;
	tier: "free" | "starter" | "pro";
}

/**
 * The plan to show, or null when there is nothing to show: self-host (no
 * billing, though the backend still says "free"), status not loaded yet, or a
 * tier this build does not know (a newer backend, a partial payload), which
 * shows nothing rather than crashing the surface it renders in.
 */
export function usePlan(): CurrentPlan | null {
	const { billingEnabled } = useConfig();
	const { data } = useBillingStatus();
	if (!(billingEnabled && data)) {
		return null;
	}
	if (data.tier === "free") {
		return { name: FREE_TIER.name, tier: "free" };
	}
	return isMember(Object.keys(PLAN_CATALOG), data.tier)
		? { name: PLAN_CATALOG[data.tier].name, tier: data.tier }
		: null;
}
