import { useUserChannelEvent } from "../api/use-user-channel-event";

interface Options {
	userId: string | null | undefined;
	enabled: boolean;
	onActivated: (payload: SubscriptionActivatedPayload) => void;
}

export interface SubscriptionActivatedPayload {
	tier: string;
	status: string;
	subscription_id: string;
}

/**
 * Fires `onActivated` on `user:{id}`'s `subscription_activated`: the Paddle
 * webhook flipped the user's subscription to trialing/active server-side (or
 * activated/updated events landed for existing subs).
 */
export function useSubscriptionActivatedEvents({ userId, enabled, onActivated }: Options): void {
	useUserChannelEvent<SubscriptionActivatedPayload>({
		userId,
		enabled,
		event: "subscription_activated",
		onEvent: onActivated,
	});
}
