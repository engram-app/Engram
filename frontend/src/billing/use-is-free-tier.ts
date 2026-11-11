import { usePlan } from "./use-plan";

/**
 * True only when paid tiers exist AND the user is on the free tier.
 *
 * Self-host (`billingEnabled=false`) has no billing and unlimited
 * connections, yet the backend still reports tier `"free"` for any
 * subscription-less user. A raw `tier === 'free'` check therefore wrongly
 * renders free-tier caps / upgrade framing on self-host. Gate every
 * free-tier UI affordance on this hook instead of comparing tier directly.
 *
 * The billing gate itself lives in usePlan, so the two can never disagree.
 */
export function useIsFreeTier(): boolean {
	return usePlan()?.tier === "free";
}
