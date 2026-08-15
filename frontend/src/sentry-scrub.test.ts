/**
 * URL scrubbing for Sentry.
 *
 * `Sentry.init({ integrations: [] })` does NOT disable the default
 * integrations — the SDK merges that array with `getDefaultIntegrations()`, and
 * only `defaultIntegrations: false` opts out. So `breadcrumbsIntegration` (fetch
 * + console + DOM) and `httpContextIntegration` (`request.url`) have always
 * been live.
 *
 * That matters here because URLs in this app carry the user's data: note and
 * attachment paths (`/attachments/Medical/labs.pdf`), unresolved wikilink
 * titles, and single-use credentials arriving as `?code=` / `?token=`. The
 * shape of a route is enough to debug it; the contents belong to the user.
 */
import { describe, expect, it } from "vitest";
import { scrubUrl } from "./sentry";

describe("scrubUrl", () => {
	it("replaces path segments, keeping the shape", () => {
		expect(scrubUrl("https://app.engram.page/attachments/Medical/labs.pdf")).toBe(
			"/:seg/:seg/:seg",
		);
	});

	it("keeps query KEYS but never values", () => {
		const out = scrubUrl("/vaults?user_code=ENGR-7X4K");
		expect(out).toContain("user_code=");
		expect(out).not.toContain("ENGR-7X4K");
	});

	// The two credentials that arrive by URL in this app. Both were live in
	// Sentry's fetch breadcrumbs and in request.url before this existed.
	it.each([
		["/link?code=ENGR-7X4K", "ENGR-7X4K"],
		["/reset-password?token=abc123secret", "abc123secret"],
	])("strips the credential in %s", (url, secret) => {
		expect(scrubUrl(url)).not.toContain(secret);
	});

	it("does not leak a note title from an unresolved wikilink", () => {
		expect(scrubUrl("/vault-slug/wiki/Divorce%20settlement%20draft")).not.toContain("Divorce");
	});

	// A relative URL has to work: fetch breadcrumbs record whatever was passed
	// to fetch(), which in this app is usually "/api/...".
	it("handles relative URLs", () => {
		expect(scrubUrl("/api/notes/Personal/Secret.md")).toBe("/:seg/:seg/:seg/:seg");
	});

	// Parsed against a base, so nearly any string resolves to a path and gets
	// scrubbed. That is the safe direction: over-scrubbing costs debug detail,
	// under-scrubbing costs the user's data. What matters is that it never
	// throws inside beforeSend — a scrubber that raises would take the whole
	// crash report with it.
	it("scrubs rather than passes through an odd value, and never throws", () => {
		expect(() => scrubUrl("not a url")).not.toThrow();
		expect(scrubUrl("not a url")).not.toContain("not a url");
	});

	it("keeps the root path recognisable", () => {
		expect(scrubUrl("https://app.engram.page/")).toBe("/");
	});
});
