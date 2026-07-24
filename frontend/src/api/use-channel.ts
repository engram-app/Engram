import { useEffect, useRef } from "react";
import { useAuthAdapter } from "../auth/use-auth-adapter";
import { installCrdtResyncTriggers } from "../crdt/session";
import { useActiveVaultId } from "./active-vault";
import {
	backfillStructural,
	connectChannel,
	disconnectChannel,
	installSocketHealthTriggers,
	reconnectWithFreshToken,
} from "./channel";
import { useMe } from "./queries";
import { queryClient } from "./query-client";

export function useChannel() {
	const { getToken } = useAuthAdapter();
	const { data: user } = useMe();
	const vaultId = useActiveVaultId();

	// The local-auth `getToken` changes identity on every token refresh (it
	// closes over `accessToken`). If the socket effect depended on it, a routine
	// token rotation (~every few minutes) would tear down and rebuild the entire
	// socket — a live-sync blackout each time. The socket only needs a token at
	// (re)connect time, so we read `getToken` through a ref and key the effect on
	// user + vault only. The connection survives token refreshes.
	const getTokenRef = useRef(getToken);
	useEffect(() => {
		getTokenRef.current = getToken;
	}, [getToken]);

	// Key the socket effect on the primitive id, not the whole `user` object: a
	// new `user` identity on every `useMe` refetch would needlessly tear the
	// socket down and back up. Hoisting `user?.id` makes the captured value and
	// the dependency the same narrow primitive.
	const userId = user?.id;
	useEffect(() => {
		if (userId === undefined || vaultId === null) {
			return;
		}

		// connectChannel's onOpen backfills the structural caches on initial
		// connect and every reconnect (see backfillStructural). No separate
		// mount/focus poll: the socket-health triggers below cover wake events.
		connectChannel({
			userId,
			vaultId,
			getToken: () => getTokenRef.current(),
			queryClient,
		});

		// CRDT catch-up on tab focus/visibility: a backgrounded tab can miss live
		// crdt_msg pushes without the socket fully reconnecting, so re-handshake
		// open docs when the tab comes back to the foreground.
		const removeCrdtResync = installCrdtResyncTriggers();

		// Re-establish a socket that went dead during a long idle / laptop sleep.
		// The triggers above assume the socket is alive; this one refreshes the
		// token and reconnects the transport in place (no CRDT-session teardown,
		// so an open editor keeps its live doc). A live socket on a short wake just
		// backfills — the online-event path the focus-only trigger misses.
		const removeHealthTriggers = installSocketHealthTriggers(
			() => reconnectWithFreshToken(() => getTokenRef.current()),
			() => backfillStructural(queryClient, vaultId),
		);

		return () => {
			disconnectChannel();
			removeCrdtResync();
			removeHealthTriggers();
		};
	}, [userId, vaultId]);
}
