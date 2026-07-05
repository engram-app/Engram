import { useSyncExternalStore } from "react";
import { isDemoVaultId } from "../onboarding/tour/demo-vault-ids";

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

export function useActiveVaultId(): string | null {
	return useSyncExternalStore(subscribe, getActiveVaultId, getActiveVaultId);
}
