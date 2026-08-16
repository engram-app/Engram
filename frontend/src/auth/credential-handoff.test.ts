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
		stashCredential("code", "ENGR-7X4K");
		expect(takeCredential("code")).toBe("ENGR-7X4K");
	});

	// Read-once: a credential must not outlive the flow it belongs to.
	it("deletes on read", () => {
		stashCredential("code", "ENGR-7X4K");
		takeCredential("code");
		expect(takeCredential("code")).toBe("");
	});

	it("returns empty for something never stashed", () => {
		expect(takeCredential("token")).toBe("");
	});

	it("picks credentials out of a query string and ignores the rest", () => {
		stashCredentialsFrom("?code=ENGR-7X4K&ref=newsletter");
		expect(takeCredential("code")).toBe("ENGR-7X4K");
		expect(takeCredential("ref")).toBe("");
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
		expect(takeCredential("code")).toBe("ENGR-7X4K");
	});

	it("does the same for a password-reset token", () => {
		const target = signInRedirectTarget({
			pathname: "/reset-password",
			search: "?token=abc123secret",
			hash: "",
		});

		expect(target).not.toContain("abc123secret");
		expect(takeCredential("token")).toBe("abc123secret");
	});

	it("stashes nothing when there is no credential", () => {
		signInRedirectTarget({ pathname: "/note/abc", search: "", hash: "" });
		expect(takeCredential("code")).toBe("");
		expect(takeCredential("token")).toBe("");
	});
});
