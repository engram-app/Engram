import { describe, expect, it } from "vitest";
import { DEFAULT_VAULT_NAME, displayVaultName } from "./vault-name";

const t = (key: string) => (key === "My Vault" ? "Mein Tresor" : key);

describe("displayVaultName", () => {
	it("translates the stored English default", () => {
		expect(displayVaultName(DEFAULT_VAULT_NAME, t)).toBe("Mein Tresor");
	});

	it("leaves any other name alone", () => {
		expect(displayVaultName("Work", t)).toBe("Work");
		expect(displayVaultName("my vault", t)).toBe("my vault");
	});
});
