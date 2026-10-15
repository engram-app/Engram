import { describe, expect, it } from "vitest";
import { copyFor } from "./limit-copy";

describe("limit-copy", () => {
	it("maps notes_cap_exceeded", () => {
		const c = copyFor("notes_cap_exceeded");
		expect(c.title).toMatch(/note limit/iu);
		expect(c.body).toBeTruthy();
	});

	it("maps attachments_disabled", () => {
		expect(copyFor("attachments_disabled").title).toMatch(/pro feature/iu);
	});

	// The Obsidian cap is a device count (Free 2 since #1981); MCP is uncapped.
	// Copy names no number so a cap change or override can't make it lie.
	it("describes the Obsidian connection cap as a device limit", () => {
		const c = copyFor("obsidian_connections_exceeded");
		expect(c.title).toMatch(/device limit/iu);
		expect(`${c.title} ${c.body}`).not.toMatch(/external connection|\b1\b|unlimited connections/iu);
	});

	it("names no stale number for the concurrent-device limit", () => {
		expect(copyFor("concurrent_devices_exceeded").body).not.toMatch(/\b1 device/iu);
	});

	it("falls back for unknown reason", () => {
		expect(copyFor("zzz_unknown").title).toMatch(/limit reached/iu);
	});
});
