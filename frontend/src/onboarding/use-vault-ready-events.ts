import { Socket } from "phoenix";
import { useEffect, useRef, useState } from "react";
import { track } from "../analytics/track";
import { getWsBase, joinWsUrl } from "../api/base";
import { useAuthAdapter } from "../auth/use-auth-adapter";

interface State {
	vaultCreated: boolean;
	vaultPopulated: boolean;
	vaultId: string | null;
}

const INITIAL: State = { vaultCreated: false, vaultPopulated: false, vaultId: null };

interface Options {
	userId: string | null | undefined;
	enabled: boolean;
}

/**
 * Subscribes to `user:{id}` for `vault_created` and `vault_populated`
 * broadcasts. Used by the FTUX vault page to wait on the Obsidian
 * plugin's first sign-in + first sync, then auto-transition off the
 * install-instructions screen.
 *
 * Returns a flat state shape so the page can render distinct copy for
 * each milestone ("Install the plugin" → "Vault detected, syncing…" →
 * navigate). Opens its own socket — it doesn't piggyback on the per-vault
 * sync socket because that one is only live AFTER a vault exists.
 */
export function useVaultReadyEvents({ userId, enabled }: Options): State {
	const { getToken } = useAuthAdapter();
	const [state, setState] = useState<State>(INITIAL);
	// Start of the wait, for vault_first_sync_completed's duration_ms — this is
	// the one milestone that proves a signup actually produced content, so how
	// long it took to land is worth carrying along with it.
	const waitStartedAtRef = useRef(Date.now());

	useEffect(() => {
		if (!enabled || userId === null || userId === undefined) {
			return;
		}
		waitStartedAtRef.current = Date.now();

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

			channel.on("vault_created", (payload: { vault_id: string }) => {
				setState((prev) => ({
					...prev,
					vaultCreated: true,
					vaultId: prev.vaultId ?? payload.vault_id,
				}));
			});

			channel.on("vault_populated", (payload: { vault_id: string }) => {
				setState((prev) => ({
					...prev,
					vaultCreated: true,
					vaultPopulated: true,
					vaultId: prev.vaultId ?? payload.vault_id,
				}));
				// ponytail: no de-dupe guard against a redelivered broadcast (e.g. a
				// reconnect replay) double-counting this event — add one if that
				// shows up in the funnel data as an inflated completion count.
				track("vault_first_sync_completed", {
					vault_id: payload.vault_id,
					duration_ms: Date.now() - waitStartedAtRef.current,
				});
			});

			channel.join().receive("error", (resp) => {
				console.error("user channel join failed", resp);
			});
		}

		// Fire-and-forget, but never let the promise dangle: a rejecting
		// getToken() (auth not ready, network error) would otherwise surface
		// as an unhandled rejection — which crashes the test runner and is
		// noise in prod. Swallow + log, mirroring the channel-join error path.
		connect().catch((err) => {
			console.error("user channel connect failed", err);
		});

		return () => {
			cancelled = true;
			if (socket) {
				socket.disconnect();
			}
		};
	}, [userId, enabled, getToken]);

	return state;
}
