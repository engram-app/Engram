import { beforeEach, describe, expect, it } from "vitest";
import {
	clearPendingAuthorization,
	peekPendingAuthorization,
	pendingCancelUrl,
	stashPendingAuthorization,
	stashPendingDeviceLink,
} from "./pending-authorization";

const SEARCH = "?client_id=cli&redirect_uri=https://app/cb&state=xyz";

describe("pending authorization stash", () => {
	beforeEach(() => {
		window.sessionStorage.clear();
	});

	it("round-trips the consent URL, the tool slug and the client name", () => {
		stashPendingAuthorization(SEARCH, "antigravity", "Google Antigravity");

		expect(peekPendingAuthorization()).toEqual({
			returnTo: `/oauth/consent${SEARCH}`,
			toolSlug: "antigravity",
			clientName: "Google Antigravity",
		});
	});

	// The plugin-first signup: Obsidian opens /link, the user signs up there,
	// and the device code has to survive the wizard the same way a consent
	// request does.
	it("parks a device-link code and returns to /link with it", () => {
		expect(stashPendingDeviceLink("ENGR-7X4K")).toBe(true);

		expect(peekPendingAuthorization()).toEqual({
			returnTo: "/link?code=ENGR-7X4K",
			toolSlug: null,
			clientName: "Obsidian",
		});
	});

	it("parks a bare /link when no code has been entered yet", () => {
		stashPendingDeviceLink("");

		expect(peekPendingAuthorization()?.returnTo).toBe("/link");
	});

	// There is no OAuth client waiting on a refusal, so there is nothing to
	// cancel to — the button must not render.
	it("has no cancel URL for a parked device link", () => {
		stashPendingDeviceLink("ENGR-7X4K");

		expect(pendingCancelUrl()).toBeNull();
	});

	it("returns null when nothing is stashed", () => {
		expect(peekPendingAuthorization()).toBeNull();
	});

	// Unlike `takeCredential`, reading does NOT consume. Several call sites ask
	// where onboarding should land, and the first one to ask must not delete
	// the answer for the rest.
	it("peek does not consume the stash", () => {
		stashPendingAuthorization(SEARCH, null, null);

		expect(peekPendingAuthorization()).not.toBeNull();
		expect(peekPendingAuthorization()).not.toBeNull();
	});

	it("clear removes it", () => {
		stashPendingAuthorization(SEARCH, null, null);
		clearPendingAuthorization();

		expect(peekPendingAuthorization()).toBeNull();
	});

	it("carries a null slug for a client we cannot attribute", () => {
		stashPendingAuthorization(SEARCH, null, null);

		expect(peekPendingAuthorization()?.toolSlug).toBeNull();
	});

	describe("rejects a tampered stash", () => {
		// sessionStorage is same-origin writable, so the value is treated as
		// untrusted input on the way out, not trusted because we wrote it.
		it("drops a returnTo pointing somewhere other than the consent page", () => {
			window.sessionStorage.setItem(
				"engram:pending-oauth",
				JSON.stringify({ returnTo: "/settings", toolSlug: null }),
			);

			expect(peekPendingAuthorization()).toBeNull();
		});

		it("drops a protocol-relative returnTo", () => {
			window.sessionStorage.setItem(
				"engram:pending-oauth",
				JSON.stringify({ returnTo: "//evil.com/oauth/consent", toolSlug: null }),
			);

			expect(peekPendingAuthorization()).toBeNull();
		});

		it("drops an absolute returnTo", () => {
			window.sessionStorage.setItem(
				"engram:pending-oauth",
				JSON.stringify({ returnTo: "https://evil.com/oauth/consent", toolSlug: null }),
			);

			expect(peekPendingAuthorization()).toBeNull();
		});

		it("drops a non-string tool slug", () => {
			window.sessionStorage.setItem(
				"engram:pending-oauth",
				JSON.stringify({ returnTo: "/oauth/consent?a=1", toolSlug: { evil: true } }),
			);

			expect(peekPendingAuthorization()?.toolSlug).toBeNull();
		});

		it("drops malformed JSON rather than throwing", () => {
			window.sessionStorage.setItem("engram:pending-oauth", "{not json");

			expect(peekPendingAuthorization()).toBeNull();
		});
	});
});

// OAuth 2.1 wants a refusal to reach the client as a standards-compliant
// error, not a browser tab the user closes. Abandoning setup mid-detour is a
// refusal, so it has to be able to say so.
describe("pendingCancelUrl", () => {
	beforeEach(() => {
		window.sessionStorage.clear();
	});

	it("is null when nothing is pending", () => {
		expect(pendingCancelUrl()).toBeNull();
	});

	it("sends access_denied back to the client with the original state", () => {
		stashPendingAuthorization(SEARCH, null, "Google Antigravity");

		expect(pendingCancelUrl()).toBe("https://app/cb?error=access_denied&state=xyz");
	});

	it("appends to a redirect that already has a query", () => {
		stashPendingAuthorization("?redirect_uri=https://app/cb%3Fa%3D1&state=xyz", null, null);

		expect(pendingCancelUrl()).toBe("https://app/cb?a=1&error=access_denied&state=xyz");
	});

	it("omits state when the request carried none", () => {
		stashPendingAuthorization("?redirect_uri=https://app/cb", null, null);

		expect(pendingCancelUrl()).toBe("https://app/cb?error=access_denied");
	});

	// Without a redirect there is nowhere to report to, and inventing one is
	// how an open redirect gets built by accident.
	it("is null when the parked request has no redirect_uri", () => {
		stashPendingAuthorization("?client_id=cli&state=xyz", null, null);

		expect(pendingCancelUrl()).toBeNull();
	});

	it("refuses a non-http redirect", () => {
		stashPendingAuthorization("?redirect_uri=javascript:alert(1)&state=xyz", null, null);

		expect(pendingCancelUrl()).toBeNull();
	});
});
