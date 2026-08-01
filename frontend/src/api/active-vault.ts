import { useSyncExternalStore } from "react";
import { isDemoVaultId } from "../onboarding/tour/demo-vault-ids";
import type { Vault } from "./queries";

const STORAGE_KEY = "engram.activeVaultId";

let activeVaultId: string | null = readStored();
const listeners = new Set<() => void>();

// The onboarding tour renders fake vaults (`demo-vault-*`) and gates a step on
// switching to one. Those ids are client-only fixtures: persisting one poisons
// the real active vault across reloads (every request then ships
// `X-Vault-Id: demo-vault-*` → backend 404s), so they update the in-memory
// selection but must never reach localStorage (see setActiveVaultId).

function readStored(): string | null {
	try {
		const raw = localStorage.getItem(STORAGE_KEY);
		if (!raw) {
			return null;
		}
		// Heal storage poisoned by a tour session that ran before the persistence
		// guard shipped: drop the demo id and clear it so it cannot be re-adopted,
		// otherwise those users 404 on every request with no self-recovery.
		if (isDemoVaultId(raw)) {
			localStorage.removeItem(STORAGE_KEY);
			return null;
		}
		return raw.length > 0 ? raw : null;
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
	// Demo vault selections stay in memory only (see isDemoVaultId).
	if (!isDemoVaultId(id)) {
		writeStored(id);
	}
	listeners.forEach((l) => {
		l();
	});
}

// Restore the in-memory selection to the persisted (real) vault, dropping any
// transient demo selection. Called when the tour deactivates so the app does
// not keep sending a `demo-vault-*` id to the real API.
export function resetActiveVaultToStored() {
	const stored = readStored();
	if (activeVaultId === stored) {
		return;
	}
	activeVaultId = stored;
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
 * with the authoritative vault list as soon as it lands (the bootstrap seed),
 * BEFORE any vault-scoped view mounts.
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
export function reconcileActiveVault(vaults: Vault[]) {
	const current = activeVaultId;
	// A live demo selection is a tour fixture and never appears in the real
	// list — reconciling it would yank the user out of the tour mid-step.
	if (current === null || isDemoVaultId(current)) {
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
