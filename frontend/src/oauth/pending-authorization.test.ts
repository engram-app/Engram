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

	it("round-trips the consent URL", () => {
		stashPendingAuthorization(SEARCH);

		expect(peekPendingAuthorization()).toEqual({
			returnTo: `/oauth/consent${SEARCH}`,
			redirectVerified: false,
		});
	});

	// The plugin-first signup: Obsidian opens /link, the user signs up there,
	// and the device code has to survive the wizard the same way a consent
	// request does.
	it("parks a device-link code and returns to /link with it", () => {
		expect(stashPendingDeviceLink("ENGR-7X4K")).toBe(true);

		expect(peekPendingAuthorization()).toEqual({
			returnTo: "/link?code=ENGR-7X4K",
			redirectVerified: false,
		});
	});

	it("parks a bare /link when no code has been entered yet", () => {
		stashPendingDeviceLink("");

		expect(peekPendingAuthorization()?.returnTo).toBe("/link");
	});

	it("returns null when nothing is stashed", () => {
		expect(peekPendingAuthorization()).toBeNull();
	});

	// Unlike `takeCredential`, reading does NOT consume. Several call sites ask
	// where onboarding should land, and the first one to ask must not delete
	// the answer for the rest.
	it("peek does not consume the stash", () => {
		stashPendingAuthorization(SEARCH);

		expect(peekPendingAuthorization()).not.toBeNull();
		expect(peekPendingAuthorization()).not.toBeNull();
	});

	it("clear removes it", () => {
		stashPendingAuthorization(SEARCH);
		clearPendingAuthorization();

		expect(peekPendingAuthorization()).toBeNull();
	});

	describe("rejects a tampered stash", () => {
		// sessionStorage is same-origin writable, so the value is treated as
		// untrusted input on the way out, not trusted because we wrote it.
		it("drops a returnTo pointing somewhere other than the consent page", () => {
			window.sessionStorage.setItem(
				"engram:pending-oauth",
				JSON.stringify({ returnTo: "/settings" }),
			);

			expect(peekPendingAuthorization()).toBeNull();
		});

		it("drops a protocol-relative returnTo", () => {
			window.sessionStorage.setItem(
				"engram:pending-oauth",
				JSON.stringify({ returnTo: "//evil.com/oauth/consent" }),
			);

			expect(peekPendingAuthorization()).toBeNull();
		});

		it("drops an absolute returnTo", () => {
			window.sessionStorage.setItem(
				"engram:pending-oauth",
				JSON.stringify({ returnTo: "https://evil.com/oauth/consent" }),
			);

			expect(peekPendingAuthorization()).toBeNull();
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

	// There is no OAuth client waiting on a refusal behind a device link.
	it("is null for a parked device link", () => {
		stashPendingDeviceLink("ENGR-7X4K");

		expect(pendingCancelUrl()).toBeNull();
	});

	// The parked query string is anyone's to write: no backend confirmation of
	// the redirect, no Cancel, or it is an open redirect.
	it("is null when the redirect was never confirmed as registered", () => {
		stashPendingAuthorization(SEARCH);

		expect(pendingCancelUrl()).toBeNull();
	});

	it("sends access_denied back to the client with the original state", () => {
		stashPendingAuthorization(SEARCH, true);

		expect(pendingCancelUrl()).toBe("https://app/cb?error=access_denied&state=xyz");
	});

	it("appends to a redirect that already has a query", () => {
		stashPendingAuthorization("?redirect_uri=https://app/cb%3Fa%3D1&state=xyz", true);

		expect(pendingCancelUrl()).toBe("https://app/cb?a=1&error=access_denied&state=xyz");
	});

	// RFC 9207 §2: an error response carries `iss` too.
	it("carries iss when the server sent one", () => {
		stashPendingAuthorization(
			"?redirect_uri=https://app/cb&state=xyz&iss=https%3A%2F%2Fmcp.engram.page",
			true,
		);

		expect(pendingCancelUrl()).toBe(
			"https://app/cb?error=access_denied&state=xyz&iss=https%3A%2F%2Fmcp.engram.page",
		);
	});

	it("omits state when the request carried none", () => {
		stashPendingAuthorization("?redirect_uri=https://app/cb", true);

		expect(pendingCancelUrl()).toBe("https://app/cb?error=access_denied");
	});

	it("is null when the parked request has no redirect_uri", () => {
		stashPendingAuthorization("?client_id=cli&state=xyz", true);

		expect(pendingCancelUrl()).toBeNull();
	});

	it("refuses a script-executing redirect", () => {
		stashPendingAuthorization("?redirect_uri=javascript:alert(1)&state=xyz", true);

		expect(pendingCancelUrl()).toBeNull();
	});
});
