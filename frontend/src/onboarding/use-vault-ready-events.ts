import { useEffect, useRef, useState } from "react";
import { track } from "../analytics/track";
import { useUserChannelEvent } from "../api/use-user-channel-event";

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
 * Listens on `user:{id}` for `vault_created` and `vault_populated`. Used by
 * the FTUX vault page to wait on the Obsidian plugin's first sign-in + first
 * sync, then auto-transition off the install-instructions screen.
 *
 * Returns a flat state shape so the page can render distinct copy for each
 * milestone ("Install the plugin" → "Vault detected, syncing…" → navigate).
 */
export function useVaultReadyEvents({ userId, enabled }: Options): State {
	const [state, setState] = useState<State>(INITIAL);
	// Start of the wait, for vault_first_sync_completed's duration_ms: this is
	// the one milestone that proves a signup actually produced content, so how
	// long it took to land is worth carrying along with it.
	const waitStartedAtRef = useRef(0);
	useEffect(() => {
		if (enabled) {
			waitStartedAtRef.current = Date.now();
		}
	}, [enabled]);

	useUserChannelEvent<{ vault_id: string }>({
		userId,
		enabled,
		event: "vault_created",
		onEvent: (payload) =>
			setState((prev) => ({
				...prev,
				vaultCreated: true,
				vaultId: prev.vaultId ?? payload.vault_id,
			})),
	});

	useUserChannelEvent<{ vault_id: string }>({
		userId,
		enabled,
		event: "vault_populated",
		onEvent: (payload) => {
			setState((prev) => ({
				...prev,
				vaultCreated: true,
				vaultPopulated: true,
				vaultId: prev.vaultId ?? payload.vault_id,
			}));
			// ponytail: no de-dupe guard against a redelivered broadcast (e.g. a
			// reconnect replay) double-counting this event; add one if that
			// shows up in the funnel data as an inflated completion count.
			track("vault_first_sync_completed", {
				vault_id: payload.vault_id,
				duration_ms: Date.now() - waitStartedAtRef.current,
			});
		},
	});

	return state;
}
