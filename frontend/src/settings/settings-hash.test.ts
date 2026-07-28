import { describe, expect, it } from "vitest";
import { isSettingsHash, parseSettingsHash, settingsHash } from "./settings-hash";

describe("isSettingsHash", () => {
	it("matches the bare prefix and sectioned forms", () => {
		expect(isSettingsHash("#settings")).toBe(true);
		expect(isSettingsHash("#settings/billing")).toBe(true);
	});

	it("rejects empty, unrelated, and prefix-lookalike hashes", () => {
		expect(isSettingsHash("")).toBe(false);
		expect(isSettingsHash("#tour")).toBe(false);
		expect(isSettingsHash("#settingsfoo")).toBe(false);
	});
});

describe("parseSettingsHash", () => {
	it("returns null for a non-settings hash", () => {
		expect(parseSettingsHash("")).toBeNull();
		expect(parseSettingsHash("#tour")).toBeNull();
	});

	it("defaults a bare prefix to account", () => {
		expect(parseSettingsHash("#settings")).toBe("account");
		expect(parseSettingsHash("#settings/")).toBe("account");
	});

	it("returns each known section", () => {
		expect(parseSettingsHash("#settings/account")).toBe("account");
		expect(parseSettingsHash("#settings/vaults")).toBe("vaults");
		expect(parseSettingsHash("#settings/connections")).toBe("connections");
		expect(parseSettingsHash("#settings/billing")).toBe("billing");
		expect(parseSettingsHash("#settings/admin")).toBe("admin");
	});

	it("maps the legacy api-keys alias to connections", () => {
		expect(parseSettingsHash("#settings/api-keys")).toBe("connections");
	});

	it("falls back to account for an unknown section", () => {
		expect(parseSettingsHash("#settings/garbage")).toBe("account");
	});
});

describe("settingsHash", () => {
	it("round-trips through parseSettingsHash", () => {
		expect(settingsHash("billing")).toBe("#settings/billing");
		expect(parseSettingsHash(settingsHash("vaults"))).toBe("vaults");
	});
});
