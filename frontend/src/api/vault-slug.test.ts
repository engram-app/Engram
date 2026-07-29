import { describe, expect, it } from "vitest";
import type { Vault } from "./queries";
import { preferredVault, vaultBySlug } from "./vault-slug";

function v(id: string, slug: string, is_default = false): Vault {
	return { id, slug, is_default, name: slug } as Vault;
}

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
