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
import { ROUTES } from "./routes";
import { scrubBreadcrumb, scrubEvent, scrubUrl, sentryInitOptions } from "./sentry";

describe("scrubUrl", () => {
	// Host and first segment survive so a breadcrumb can still say WHICH
	// endpoint failed; everything after is the user's.
	it("keeps the host and first segment, redacts the rest", () => {
		const app = window.location.origin;
		expect(scrubUrl(`${app}/attachments/Medical/labs.pdf`)).toBe(`${app}/attachments/:seg/:seg`);
	});

	it("does not leak a folder or filename", () => {
		const out = scrubUrl(`${window.location.origin}/attachments/Medical/2026-lab-results.pdf`);
		expect(out).not.toContain("Medical");
		expect(out).not.toContain("lab-results");
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

	// The bug this allowlist exists for. `/:slug` is the vault route and the
	// slug is slugify(vault.name), so segment 1 on the app's most-travelled
	// route IS user data. The wikilink test above passed throughout, because
	// it only asserted on the note title and never looked at "vault-slug".
	it("redacts the vault slug, which is a user-typed vault name", () => {
		const app = window.location.origin;
		expect(scrubUrl(`${app}/divorce-2026/note-abc`)).toBe(`${app}/:seg/:seg`);
		expect(scrubUrl(`${app}/my-therapy-vault`)).toBe(`${app}/:seg`);
		// Relative is the same surface — that is what fetch breadcrumbs carry
		// on self-host.
		expect(scrubUrl("/divorce-2026/note-abc")).toBe("/:seg/:seg");
	});

	// On SaaS the API lives on its own host AND joinApiUrl strips the `/api`
	// prefix, so these arrive as `/search`, `/folders`, `/notes`. Applying the
	// route allowlist to them redacted every endpoint name in prod — and SaaS
	// is the only deployment with a DSN, so that was the only behaviour that
	// ran. A foreign origin cannot carry a vault slug in segment 1.
	it("keeps the endpoint name on a foreign origin, and still redacts below it", () => {
		expect(scrubUrl("https://api.engram.page/search?q=cancer")).toBe(
			"https://api.engram.page/search?q=:v",
		);
		expect(scrubUrl("https://api.engram.page/notes/Medical/labs.md")).toBe(
			"https://api.engram.page/notes/:seg/:seg",
		);
		expect(scrubUrl("https://api.engram.page/folders")).toBe("https://api.engram.page/folders");
	});

	it("still keeps our own route segments, which is the point of keeping any", () => {
		expect(scrubUrl("/api/search")).toBe("/api/:seg");
		expect(scrubUrl("/attachments/Medical/labs.pdf")).toBe("/attachments/:seg/:seg");
		expect(scrubUrl("/onboard/billing")).toBe("/onboard/:seg");
	});

	// Drift guard. A route renamed in ROUTES without updating the allowlist
	// would start being redacted (merely unhelpful), but a route REMOVED from
	// ROUTES while a vault slug of the same name exists is the leak direction.
	// Either way the two lists must agree, and this fails when they don't.
	it("keeps every first segment declared in ROUTES", () => {
		const app = window.location.origin;
		for (const route of Object.values(ROUTES)) {
			const [, segment] = route.split("/");
			if (!segment) {
				continue;
			}
			expect(scrubUrl(`${app}/${segment}/x`)).toBe(`${app}/${segment}/:seg`);
		}
	});

	// Fails closed. In a worker or SSR there is no `window`, so origin cannot be
	// compared — and the safe answer is to treat the URL as ours and apply the
	// allowlist, not to keep an unrecognised segment.
	it("redacts an unknown first segment when there is no window to compare", () => {
		const realWindow = globalThis.window;
		delete (globalThis as { window?: unknown }).window;
		try {
			expect(scrubUrl("https://app.engram.page/divorce-2026/x")).toBe(
				"https://app.engram.page/:seg/:seg",
			);
		} finally {
			(globalThis as { window?: unknown }).window = realWindow;
		}
	});

	// A relative URL has to work: fetch breadcrumbs record whatever was passed
	// to fetch(), which in this app is usually "/api/...".
	it("handles relative URLs, and keeps them relative", () => {
		expect(scrubUrl("/api/notes/Personal/Secret.md")).toBe("/api/:seg/:seg/:seg");
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
		expect(scrubUrl(`${window.location.origin}/`)).toBe(`${window.location.origin}/`);
	});

	// The fragment carries heading slugs derived from note body text.
	it("drops the fragment entirely", () => {
		expect(scrubUrl("/vault/notes#Divorce-settlement-heading")).not.toContain("Divorce");
	});
});

describe("scrubBreadcrumb", () => {
	// Console args are whatever a developer passed — an attachment path today,
	// anything tomorrow. Not worth a privacy review on every future edit.
	it("drops console breadcrumbs entirely", () => {
		expect(scrubBreadcrumb({ category: "console", message: "attachment load failed" })).toBeNull();
	});

	// The DOM serializer reads title/alt/aria-label off the clicked element AND
	// five ancestors. In this app those carry note paths, filenames and
	// frontmatter values.
	it.each(["ui.click", "ui.input"])("drops %s breadcrumbs", (category) => {
		expect(scrubBreadcrumb({ category })).toBeNull();
	});

	it("keeps fetch breadcrumbs but scrubs the url", () => {
		const crumb = scrubBreadcrumb({
			category: "fetch",
			data: { url: "https://app.engram.page/api/attachments/Medical/labs.pdf", status_code: 500 },
		});

		expect(crumb).not.toBeNull();
		expect(crumb?.data?.url).not.toContain("Medical");
		// The endpoint is still identifiable — over-scrubbing to "/:seg/:seg"
		// made breadcrumbs useless at the moment reporting was switched on.
		expect(crumb?.data?.url).toContain("/api/");
		expect(crumb?.data?.status_code).toBe(500);
	});

	it("scrubs navigation from/to", () => {
		const crumb = scrubBreadcrumb({
			category: "navigation",
			data: { from: "/link?code=ENGR-7X4K", to: "/vault/Personal/Secret.md" },
		});

		expect(crumb?.data?.from).not.toContain("ENGR-7X4K");
		expect(crumb?.data?.to).not.toContain("Secret");
	});
});

describe("scrubEvent", () => {
	it("scrubs request.url", () => {
		const out = scrubEvent({ request: { url: "/reset-password?token=abc123secret" } });
		expect(JSON.stringify(out)).not.toContain("abc123secret");
	});

	// httpContextIntegration attaches headers too, and Referer is the full URL
	// of the page while the credential is still in the address bar.
	it("scrubs the Referer header, not just the url", () => {
		const out = scrubEvent({
			request: {
				url: "/api/notes",
				headers: { Referer: "https://app.engram.page/link?code=ENGR-7X4K" },
			},
		});

		expect(JSON.stringify(out)).not.toContain("ENGR-7X4K");
	});

	// Header names are case-insensitive by spec. The scrub used to match the
	// exact key `Referer`, which works only because httpContextIntegration
	// happens to capitalize it that way.
	it("scrubs a lowercased referer header too", () => {
		const event = {
			request: {
				url: "https://app.engram.page/reset-password",
				headers: { referer: "https://app.engram.page/reset-password?token=secret-tok" },
			},
		};
		expect(scrubEvent(event).request.headers.referer).not.toContain("secret-tok");
	});
});

describe("the scrubbers are actually wired into Sentry.init", () => {
	// Without this, deleting the two hook lines from the options left every
	// other test in this file green while everything shipped unscrubbed.
	it("passes beforeBreadcrumb and beforeSend", () => {
		const opts = sentryInitOptions("https://key@example.ingest.sentry.io/1");
		expect(opts.beforeBreadcrumb).toBe(scrubBreadcrumb);
		expect(opts.beforeSend).toBe(scrubEvent);
		expect(opts.sendDefaultPii).toBe(false);
	});
});
