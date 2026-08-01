import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
	getActiveVaultId,
	reconcileActiveVault,
	resetActiveVaultToStored,
	setActiveVaultId,
} from "./active-vault";
import type { Vault } from "./queries";

const KEY = "engram.activeVaultId";

function v(id: string, slug: string, is_default = false): Vault {
	return { id, slug, is_default, name: slug } as Vault;
}

// resetActiveVaultToStored() re-reads localStorage into the module, so clearing
// storage then calling it returns the module to a clean (null) baseline.
function reset() {
	localStorage.clear();
	resetActiveVaultToStored();
}

describe("active-vault persistence", () => {
	beforeEach(reset);
	afterEach(reset);

	it("persists a real vault id to localStorage", () => {
		setActiveVaultId("42");
		expect(getActiveVaultId()).toBe("42");
		expect(localStorage.getItem(KEY)).toBe("42");
	});

	it("does not persist a demo-vault id, but updates the in-memory value", () => {
		// The onboarding tour drives a real switch to a fake vault; it must reflect
		// live (so the switcher + tour gate work) without touching localStorage.
		setActiveVaultId("demo-vault-2");
		expect(getActiveVaultId()).toBe("demo-vault-2");
		expect(localStorage.getItem(KEY)).toBeNull();
	});

	it("leaves a previously-stored real vault id intact when a demo vault is selected", () => {
		setActiveVaultId("42");
		setActiveVaultId("demo-vault-2");
		// In-memory follows the demo selection, but the persisted real vault survives.
		expect(getActiveVaultId()).toBe("demo-vault-2");
		expect(localStorage.getItem(KEY)).toBe("42");
	});

	it("heals storage already poisoned by a pre-fix tour session (drops + clears a demo id)", () => {
		// A user who ran the tour before this fix shipped has a demo id persisted.
		// On next load it must NOT be adopted, and must be cleared so it cannot
		// re-poison later reads (otherwise they 404 forever with no self-recovery).
		localStorage.setItem(KEY, "demo-vault-2");
		resetActiveVaultToStored();
		expect(getActiveVaultId()).toBeNull();
		expect(localStorage.getItem(KEY)).toBeNull();
	});
});

describe("resetActiveVaultToStored", () => {
	beforeEach(reset);
	afterEach(reset);

	it("drops a transient demo selection and restores the persisted real vault", () => {
		setActiveVaultId("42");
		setActiveVaultId("demo-vault-2");
		resetActiveVaultToStored();
		expect(getActiveVaultId()).toBe("42");
	});

	it("resets to null when nothing is stored (new user leaving the demo)", () => {
		setActiveVaultId("demo-vault-1");
		resetActiveVaultToStored();
		expect(getActiveVaultId()).toBeNull();
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

	it("leaves a live demo selection alone", () => {
		// The tour's fake vaults are never in the real list; reconciling against it
		// would yank the user out of the demo mid-tour.
		setActiveVaultId("id-a");
		setActiveVaultId("demo-vault-2");
		reconcileActiveVault(owned);
		expect(getActiveVaultId()).toBe("demo-vault-2");
		expect(localStorage.getItem(KEY)).toBe("id-a");
	});
});
