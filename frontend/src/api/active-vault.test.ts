import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { getActiveVaultId, reconcileActiveVault, setActiveVaultId } from "./active-vault";
import type { Vault } from "./queries";

const KEY = "engram.activeVaultId";

function v(id: string, slug: string, is_default = false): Vault {
	return { id, slug, is_default, name: slug } as Vault;
}

// The store is module state, so each test has to return it to a clean (null)
// baseline explicitly; selecting null also clears the persisted key.
function reset() {
	setActiveVaultId(null);
	localStorage.clear();
}

describe("active-vault persistence", () => {
	beforeEach(reset);
	afterEach(reset);

	it("persists a real vault id to localStorage", () => {
		setActiveVaultId("42");
		expect(getActiveVaultId()).toBe("42");
		expect(localStorage.getItem(KEY)).toBe("42");
	});
});

describe("reconcileActiveVault", () => {
	beforeEach(reset);
	afterEach(reset);

	const owned = [v("id-a", "work"), v("id-b", "personal", true)];

	it("re-points a stored id the account no longer owns at the default vault", () => {
		// Vault deleted from another device / environment DB wiped. The id is a
		// well-formed UUID, so nothing else rejects it: it keeps riding along as
		// X-Vault-ID and every vault-scoped request 404s.
		setActiveVaultId("dead-vault");
		reconcileActiveVault(owned);
		expect(getActiveVaultId()).toBe("id-b");
		expect(localStorage.getItem(KEY)).toBe("id-b");
	});

	it("falls back to the first vault when none is flagged default", () => {
		setActiveVaultId("dead-vault");
		reconcileActiveVault([v("id-a", "work"), v("id-c", "archive")]);
		expect(getActiveVaultId()).toBe("id-a");
	});

	it("keeps a stored id that still exists", () => {
		setActiveVaultId("id-a");
		reconcileActiveVault(owned);
		// Not re-pointed at the default: the user's own choice wins over is_default.
		expect(getActiveVaultId()).toBe("id-a");
		expect(localStorage.getItem(KEY)).toBe("id-a");
	});

	it("clears the selection when the account owns no vaults at all", () => {
		setActiveVaultId("dead-vault");
		reconcileActiveVault([]);
		expect(getActiveVaultId()).toBeNull();
		expect(localStorage.getItem(KEY)).toBeNull();
	});

	it("no-ops on a payload with no vault list instead of throwing", () => {
		// It runs inside queryFns; throwing here would fail the bootstrap query and
		// take down the whole authenticated shell.
		setActiveVaultId("dead-vault");
		expect(() => {
			reconcileActiveVault(undefined);
		}).not.toThrow();
		expect(getActiveVaultId()).toBe("dead-vault");
	});

	it("no-ops when nothing is selected", () => {
		reconcileActiveVault(owned);
		expect(getActiveVaultId()).toBeNull();
		expect(localStorage.getItem(KEY)).toBeNull();
	});

	it("re-points a leftover demo-vault id from the removed onboarding tour", () => {
		// Storage written by an early tour build persists a client-only fixture id
		// that 404s every vault-scoped request. It is just an unowned id now, so
		// the normal reconcile path heals it.
		localStorage.setItem(KEY, "demo-vault-2");
		setActiveVaultId("demo-vault-2");
		reconcileActiveVault(owned);
		expect(getActiveVaultId()).toBe("id-b");
		expect(localStorage.getItem(KEY)).toBe("id-b");
	});
});
