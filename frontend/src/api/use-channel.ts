import { useEffect, useRef } from "react";
import { useAuthAdapter } from "../auth/use-auth-adapter";
import { installCrdtResyncTriggers } from "../crdt/session";
import { useActiveVaultId } from "./active-vault";
import { connectChannel, disconnectChannel } from "./channel";
import { installCursorSyncTriggers, runCursorSync } from "./cursor-sync";
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

	useEffect(() => {
		if (!user || vaultId === null) {
			return;
		}

		connectChannel({
			userId: user.id,
			vaultId,
			getToken: () => getTokenRef.current(),
			queryClient,
			// Reconnect (and initial connect) → backfill missed changes via the
			// durable cursor feed. Single-flight dedupes against the mount run below.
			onSocketOpen: () => runCursorSync(vaultId, queryClient),
		});

		// Run on mount + on every window focus; returns a listener cleanup.
		const removeTriggers = installCursorSyncTriggers(vaultId, queryClient);

		// CRDT catch-up on tab focus/visibility: a backgrounded tab can miss live
		// crdt_msg pushes without the socket fully reconnecting, so re-handshake
		// open docs when the tab comes back to the foreground.
		const removeCrdtResync = installCrdtResyncTriggers();

		return () => {
			disconnectChannel();
			removeTriggers();
			removeCrdtResync();
		};
	}, [user?.id, vaultId]);
}
