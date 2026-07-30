import { renderHook } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { setActiveVaultId } from "./active-vault";
import type { Vault } from "./queries";
import { preferredVault, useActiveVaultSlug, vaultBySlug } from "./vault-slug";

function v(id: string, slug: string, is_default = false): Vault {
	return { id, slug, is_default, name: slug } as Vault;
}

// useActiveVaultSlug is the sole slug source for four link sites and every
// consumer test mocks it, so it needs its own coverage: a rename of
// Vault.slug should not be able to ship green.
let mockVaults: Vault[] | undefined;

vi.mock("./queries", () => ({
	useVaults: () => ({ data: mockVaults }),
}));

const vaults = [v("id-a", "work"), v("id-b", "personal", true), v("id-c", "archive")];

describe("vaultBySlug", () => {
	it("finds a vault by slug", () => {
		expect(vaultBySlug(vaults, "personal")?.id).toBe("id-b");
	});

	it("returns null for an unknown slug", () => {
		expect(vaultBySlug(vaults, "nope")).toBeNull();
	});

	it("returns null when vaults or slug are missing", () => {
		expect(vaultBySlug(undefined, "work")).toBeNull();
		expect(vaultBySlug(vaults, undefined)).toBeNull();
	});
});

describe("preferredVault", () => {
	it("prefers the hinted vault", () => {
		expect(preferredVault(vaults, "id-c")?.slug).toBe("archive");
	});

	it("falls back to the default when the hint is stale", () => {
		expect(preferredVault(vaults, "id-gone")?.slug).toBe("personal");
	});

	it("falls back to the default when there is no hint", () => {
		expect(preferredVault(vaults, null)?.slug).toBe("personal");
	});

	it("falls back to the first vault when none is marked default", () => {
		expect(preferredVault([v("id-a", "work"), v("id-c", "archive")], null)?.slug).toBe("work");
	});

	it("returns null when there are no vaults", () => {
		expect(preferredVault([], null)).toBeNull();
		expect(preferredVault(undefined, "id-a")).toBeNull();
	});
});

describe("useActiveVaultSlug", () => {
	beforeEach(() => {
		mockVaults = undefined;
		setActiveVaultId(null);
	});

	it("returns null before the vault list loads", () => {
		setActiveVaultId("id-a");
		const { result } = renderHook(() => useActiveVaultSlug());
		expect(result.current).toBeNull();
	});

	it("returns the slug of the active vault", () => {
		mockVaults = vaults;
		setActiveVaultId("id-b");
		const { result } = renderHook(() => useActiveVaultSlug());
		expect(result.current).toBe("personal");
	});

	it("returns null when the active id matches no vault", () => {
		mockVaults = vaults;
		setActiveVaultId("id-gone");
		const { result } = renderHook(() => useActiveVaultSlug());
		expect(result.current).toBeNull();
	});
});
