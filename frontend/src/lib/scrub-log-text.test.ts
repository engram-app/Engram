import { describe, expect, it } from "vitest";
import { scrubLogText } from "./scrub-log-text";

// Mirrors the plugin's tests/remote-log-privacy.test.ts and the server's
// text_scrubber_test.exs: the three scrubbers must agree.
describe("scrubLogText", () => {
	it("redacts a quoted path, keeping the quote", () => {
		const out = scrubLogText("ENOENT: no such file, open '/home/alice/Vault/Medical/biopsy.md'");
		expect(out).not.toMatch(/biopsy|alice|Medical/u);
		expect(out).toMatch(/ENOENT/u);
	});

	it("fully redacts a spaced vault-relative title", () => {
		const out = scrubLogText("push failed for Medical/Divorce settlement draft.md, retrying");
		expect(out).not.toMatch(/Medical|Divorce|settlement/u);
		expect(out).toMatch(/push failed for/u);
	});

	it("does not treat apostrophes inside words as quotes", () => {
		const msg = "can't push n3 | route=/api/notes | reason=won't retry";
		expect(scrubLogText(msg)).toBe(msg);
	});

	it("exempts a quoted API route", () => {
		expect(scrubLogText('{"route":"/api/notes"}')).toBe('{"route":"/api/notes"}');
	});

	it("keeps a route before the prose", () => {
		expect(scrubLogText("POST /api/notes returned 500 for Medical/x y.md")).toBe(
			"POST /api/notes returned 500 for <path>",
		);
	});
});
