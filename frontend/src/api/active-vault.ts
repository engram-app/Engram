import { useSyncExternalStore } from "react";
import type { Vault } from "./queries";

const STORAGE_KEY = "engram.activeVaultId";

let activeVaultId: string | null = readStored();
const listeners = new Set<() => void>();

function readStored(): string | null {
	try {
		const raw = localStorage.getItem(STORAGE_KEY);
		return raw && raw.length > 0 ? raw : null;
	} catch {
		return null;
	}
}

function writeStored(id: string | null) {
	try {
		if (id === null) {
			localStorage.removeItem(STORAGE_KEY);
		} else {
			localStorage.setItem(STORAGE_KEY, id);
		}
	} catch {
		// ignore — private browsing, etc.
	}
}

function subscribe(listener: () => void): () => void {
	listeners.add(listener);
	return () => {
		listeners.delete(listener);
	};
}

export function getActiveVaultId(): string | null {
	return activeVaultId;
}

export function setActiveVaultId(id: string | null) {
	if (activeVaultId === id) {
		return;
	}
	activeVaultId = id;
	writeStored(id);
	listeners.forEach((l) => {
		l();
	});
}

// Used wherever the URL does NOT name a vault: the bare `/` redirect, the
// legacy `/note/:id` redirect, and reconcileActiveVault below. `hintId` is the
// last-used vault (this store); it is a hint, not authority, so a stale id
// silently degrades to the default vault.
export function preferredVault(vaults: Vault[] | undefined, hintId: string | null): Vault | null {
	if (!vaults || vaults.length === 0) {
		return null;
	}
	return (
		(hintId ? vaults.find((v) => v.id === hintId) : undefined) ??
		vaults.find((v) => v.is_default) ??
		vaults[0] ??
		null
	);
}

/**
 * Re-point a persisted selection at a vault the account actually owns. Call it
 * from every path that learns the authoritative vault list — the bootstrap seed
 * (before any vault-scoped view mounts) and the /vaults fetch itself, which is
 * what a delete/purge invalidation refetches through.
 *
 * A stored id whose vault is gone — deleted from another device, or an env
 * whose DB was wiped — is strictly worse than no selection at all: it is a
 * well-formed UUID, so nothing rejects it client-side, and client.ts ships it
 * as `X-Vault-ID` on every request. The backend's VaultPlug then 404s the whole
 * vault-scoped API (folders, attachments, notes, search). Only `/v/:slug` heals
 * itself (VaultRoute makes the URL authoritative); on `/settings/*` and friends
 * there is no slug, so the dead id sticks across reloads forever.
 *
 * Re-pointing (rather than clearing) is load-bearing for live sync: useChannel
 * skips connecting entirely while the active vault is null, so clearing would
 * trade the 404s for a silently dead socket.
 */
export function reconcileActiveVault(vaults: Vault[] | undefined) {
	const current = activeVaultId;
	// `vaults` is optional so a payload missing the list can't throw from inside
	// a queryFn: healing is best-effort, and taking the bootstrap query (and
	// with it the whole authenticated shell) down over it would be a far worse
	// failure than the 404s this exists to prevent.
	if (!vaults || current === null) {
		return;
	}
	if (vaults.some((v) => v.id === current)) {
		return;
	}
	setActiveVaultId(preferredVault(vaults, null)?.id ?? null);
}

export function useActiveVaultId(): string | null {
	return useSyncExternalStore(subscribe, getActiveVaultId, getActiveVaultId);
}
