import { useBillingStatus } from "../api/queries";
import { useConfig } from "../config-context";

/**
 * True only when paid tiers exist AND the user is on the free tier.
 *
 * Self-host (`billingEnabled=false`) has no billing and unlimited
 * connections, yet the backend still reports tier `"free"` for any
 * subscription-less user. A raw `tier === 'free'` check therefore wrongly
 * renders free-tier caps / upgrade framing on self-host. Gate every
 * free-tier UI affordance on this hook instead of comparing tier directly.
 */
export function useIsFreeTier(): boolean {
	const { billingEnabled } = useConfig();
	const { data } = useBillingStatus();
	if (!billingEnabled) {
		return false;
	}
	return data?.tier === "free" || data?.tier === "none";
}
