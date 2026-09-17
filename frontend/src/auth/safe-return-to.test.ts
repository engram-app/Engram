import { describe, expect, it } from "vitest";
import { safeReturnTo } from "./safe-return-to";

describe("safeReturnTo", () => {
	it("keeps a relative destination, query and hash intact", () => {
		expect(safeReturnTo("/settings?tab=billing#plan")).toBe("/settings?tab=billing#plan");
	});

	it("keeps a consent URL whose own query holds an encoded redirect_uri", () => {
		const consent = "/oauth/consent?client_id=abc&redirect_uri=https%3A%2F%2Fclaude.ai%2Fcb";
		expect(safeReturnTo(consent)).toBe(consent);
	});

	it("falls back home on nothing", () => {
		expect(safeReturnTo(null)).toBe("/");
		expect(safeReturnTo("")).toBe("/");
	});

	// `return_to` reaches Clerk as `forceRedirectUrl` and `navigate()` as a raw
	// string, and both end at `window.location.assign` for anything off-origin.
	// A victim completes a REAL signup on the REAL domain and is then handed to
	// the attacker, which is what makes this a strong phishing primitive.
	describe("refuses to leave the origin", () => {
		it.each([
			["absolute", "https://evil.com/pwn"],
			["scheme-relative", "//evil.com/pwn"],
			["backslash-degraded", "/\\evil.com/pwn"],
			// WHATWG URL parsing STRIPS tab/CR/LF before parsing, so each of
			// these degrades to `//evil.com` inside `new URL` while sailing past
			// any prefix check written against the raw string.
			["tab-smuggled", "/\t/evil.com/pwn"],
			["newline-smuggled", "/\n/evil.com/pwn"],
			["carriage-return-smuggled", "/\r/evil.com/pwn"],
			["script scheme", "javascript:alert(1)"],
			["data scheme", "data:text/html,<script>alert(1)</script>"],
		])("rejects a %s destination", (_label, raw) => {
			expect(safeReturnTo(raw)).toBe("/");
		});
	});
});
