/**
 * The sign-in handoff for URL-borne credentials.
 *
 * Stripping the device code and the reset token out of `return_to` kept them
 * out of the address bar, history, and Clerk — and broke both flows, because
 * the destination page read them from the URL that no longer had them. The
 * signed-out arrival is the COMMON case for `/link`: the plugin opens
 * `verification_uri_complete` for someone who has never signed in to that
 * browser.
 *
 * sessionStorage carries them across instead: per-tab, dies with the tab, never
 * sent with a request, never in history.
 */
import { beforeEach, describe, expect, it } from "vitest";
import { stashCredential, stashCredentialsFrom, takeCredential } from "./credential-handoff";
import { signInRedirectTarget } from "./sign-in-redirect";

beforeEach(() => {
	window.sessionStorage.clear();
});

describe("credential handoff", () => {
	it("round-trips a value", () => {
		stashCredential("code", "ENGR-7X4K", "/link");
		expect(takeCredential("code", "/link")).toBe("ENGR-7X4K");
	});

	// Read-once: a credential must not outlive the flow it belongs to.
	it("deletes on read", () => {
		stashCredential("code", "ENGR-7X4K", "/link");
		takeCredential("code", "/link");
		expect(takeCredential("code", "/link")).toBe("");
	});

	it("returns empty for something never stashed", () => {
		expect(takeCredential("token", "/reset-password")).toBe("");
	});

	// The stale-handoff bug. Abandon sign-in from /link?code=A, then reach
	// /link again later in the same tab from the onboarding wizard's Obsidian
	// branch — which wants an EMPTY input to type a fresh code into. The old
	// code was consumed, prefilled, and auto-verified straight into "This code
	// is invalid or has expired."
	it("refuses a credential captured on a different path", () => {
		stashCredential("code", "OLDX-CODE", "/link");
		expect(takeCredential("code", "/reset-password")).toBe("");
	});

	// Rejecting still consumes: the page that just refused it is the only
	// reader, so leaving it would surface it again on the next navigation.
	it("drops a rejected credential rather than leaving it to resurface", () => {
		stashCredential("code", "OLDX-CODE", "/link");
		takeCredential("code", "/reset-password");
		expect(takeCredential("code", "/link")).toBe("");
	});

	// React-router matches `/link/` and `/Link` to `path="/link"` but leaves
	// `pathname` as written. The stash side reads location.pathname; the page
	// names its own route. Without normalization those disagree and the code is
	// dropped silently — and unrecoverably, since a rejected stash is removed.
	it.each(["/link/", "/Link", "/LINK/", "/link//", "/Link///"])(
		"matches %s against /link",
		(arrival) => {
			stashCredential("code", "ENGR-7X4K", arrival);
			expect(takeCredential("code", "/link")).toBe("ENGR-7X4K");
		},
	);

	// Normalizing must not make unrelated paths collide.
	it("still rejects a genuinely different path", () => {
		stashCredential("code", "ENGR-7X4K", "/linkedin");
		expect(takeCredential("code", "/link")).toBe("");
	});

	// A tab left open across a deploy holds a stash written by the old build:
	// a bare string with no stamp. Unverifiable means dropped — the user
	// retypes, which is what they did before any of this existed.
	it("drops an unstamped stash from a previous build", () => {
		window.sessionStorage.setItem("engram:handoff:code", "ENGR-7X4K");
		expect(takeCredential("code", "/link")).toBe("");
	});

	it("picks credentials out of a query string and ignores the rest", () => {
		stashCredentialsFrom("?code=ENGR-7X4K&ref=newsletter", "/link");
		expect(takeCredential("code", "/link")).toBe("ENGR-7X4K");
		expect(takeCredential("ref", "/link")).toBe("");
	});
});

describe("the redirect hands the credential over before stripping it", () => {
	// The regression this exists for: strip-only meant a first-time linker
	// landed on a bare /link with nothing prefilled, i.e. the retyping that
	// RFC 8628's complete URL exists to avoid.
	it("keeps the device code available after it leaves the URL", () => {
		const target = signInRedirectTarget({
			pathname: "/link",
			search: "?code=ENGR-7X4K",
			hash: "",
		});

		expect(target).not.toContain("ENGR-7X4K");
		expect(takeCredential("code", "/link")).toBe("ENGR-7X4K");
	});

	it("does the same for a password-reset token", () => {
		const target = signInRedirectTarget({
			pathname: "/reset-password",
			search: "?token=abc123secret",
			hash: "",
		});

		expect(target).not.toContain("abc123secret");
		expect(takeCredential("token", "/reset-password")).toBe("abc123secret");
	});

	it("stashes nothing when there is no credential", () => {
		signInRedirectTarget({ pathname: "/note/abc", search: "", hash: "" });
		expect(takeCredential("code", "/note/abc")).toBe("");
		expect(takeCredential("token", "/note/abc")).toBe("");
	});

	// `code` is a generic param — OAuth callbacks and promo links use it too.
	// Only the device-link page reads it, so a `code` captured anywhere else
	// must not reach it.
	it("does not hand a code captured elsewhere to the device-link page", () => {
		signInRedirectTarget({ pathname: "/some-vault", search: "?code=PROMO123", hash: "" });
		expect(takeCredential("code", "/link")).toBe("");
	});
});
