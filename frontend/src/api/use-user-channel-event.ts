import { useEffect, useRef } from "react";
import { useAuthAdapter } from "../auth/use-auth-adapter";
import { subscribeUserChannel } from "./channel";

/**
 * Runs `onEvent` for every `event` broadcast on `user:{id}`
 * (lib/engram_web/channels/user_channel.ex lists them), and `onJoined` after
 * each (re)join of the channel. Rides the tab's one socket (api/channel.ts),
 * so any number of these share one channel and one connection.
 */
export function useUserChannelEvent<P>({
	userId,
	event,
	onEvent,
	onJoined,
	enabled = true,
}: {
	userId: string | null | undefined;
	event: string;
	onEvent: (payload: P) => void;
	onJoined?: () => void;
	enabled?: boolean;
}): void {
	const { getToken } = useAuthAdapter();
	// Latest handlers without resubscribing on every render.
	const handlers = useRef({ onEvent, onJoined });
	useEffect(() => {
		handlers.current = { onEvent, onJoined };
	}, [onEvent, onJoined]);

	useEffect(() => {
		if (!enabled || userId === null || userId === undefined) {
			return;
		}
		let unsubscribe: (() => void) | null = null;
		let cancelled = false;
		subscribeUserChannel(
			{ userId, getToken },
			event,
			(payload: P) => handlers.current.onEvent(payload),
			() => handlers.current.onJoined?.(),
		)
			.then((off) => {
				if (cancelled) {
					off();
				} else {
					unsubscribe = off;
				}
			})
			// Never let the fire-and-forget promise dangle as an unhandled rejection.
			.catch((err: unknown) => console.error(`user channel subscribe failed (${event})`, err));
		return () => {
			cancelled = true;
			unsubscribe?.();
		};
	}, [event, enabled, userId, getToken]);
}
