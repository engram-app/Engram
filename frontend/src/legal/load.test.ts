import { describe, expect, it } from "vitest";
import { loadVersion, renderableVersion, sha256Hex } from "./load";

describe("sha256Hex", () => {
	it("matches canonical lowercase-hex sha256 of UTF-8 bytes", async () => {
		expect(await sha256Hex("abc")).toBe(
			"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
		);
		expect(await sha256Hex("# Terms of Service\n")).toMatch(/^[0-9a-f]{64}$/u);
	});
});

describe("loadVersion", () => {
	it("loads the bundled terms markdown", async () => {
		await expect(loadVersion("terms", "2026-05-19")).resolves.toMatch(/^# Terms of Service/u);
	});

	it("rejects an unknown version", async () => {
		await expect(loadVersion("terms", "9999-99-99")).rejects.toThrow(/missing bundled/u);
	});
});

// A bundle built before a publish cannot render the backend's newest version;
// it falls back to the newest one it ships that is not newer.
describe("renderableVersion", () => {
	it("is the version itself when bundled", () => {
		expect(renderableVersion("privacy", "2026-10-12")).toBe("2026-10-12");
	});

	it("is the newest bundled version not newer than the wanted one", () => {
		expect(renderableVersion("privacy", "2026-10-13")).toBe("2026-10-12");
	});

	it("is undefined when nothing bundled is that old", () => {
		expect(renderableVersion("privacy", "2000-01-01")).toBeUndefined();
	});
});
