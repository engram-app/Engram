import { Socket } from "phoenix";
import { useEffect, useRef } from "react";
import { useAuthAdapter } from "../auth/use-auth-adapter";
import { getWsBase, joinWsUrl } from "./base";
import { useMe } from "./queries";

/**
 * Runs `onEvent` for every `event` broadcast on the signed-in user's
 * `user:{id}` channel (lib/engram_web/channels/user_channel.ex lists them).
 * Opens its own socket while `enabled`, the same lifecycle as the older
 * per-event hooks (`useVaultReadyEvents`, `useSubscriptionActivatedEvents`).
 */
export function useUserChannelEvent<P>(
	event: string,
	onEvent: (payload: P) => void,
	enabled = true,
): void {
	const { getToken } = useAuthAdapter();
	const userId = useMe().data?.id ?? null;
	// Latest handler without resubscribing on every render.
	const handler = useRef(onEvent);
	useEffect(() => {
		handler.current = onEvent;
	}, [onEvent]);

	useEffect(() => {
		if (!enabled || userId === null) {
			return;
		}
		let socket: Socket | null = null;
		let cancelled = false;

		async function connect() {
			const token = await getToken();
			if (cancelled || !token) {
				return;
			}
			socket = new Socket(joinWsUrl(getWsBase(), "/socket"), { params: { token } });
			socket.connect();
			const channel = socket.channel(`user:${userId}`);
			channel.on(event, (payload: P) => handler.current(payload));
			channel.join().receive("error", (resp) => {
				console.error(`user channel join failed (${event} listener)`, resp);
			});
		}

		// Never let the fire-and-forget promise dangle as an unhandled rejection.
		connect().catch((err) => {
			console.error(`user channel connect failed (${event} listener)`, err);
		});
		return () => {
			cancelled = true;
			socket?.disconnect();
		};
	}, [event, enabled, userId, getToken]);
}
