import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { getActiveVaultId, resetActiveVaultToStored, setActiveVaultId } from "./active-vault";

const KEY = "engram.activeVaultId";

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
