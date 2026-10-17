import { beforeEach, describe, expect, it } from "vitest";
import {
	clearPendingAuthorization,
	connecting,
	connectingUrl,
	peekPendingAuthorization,
	pendingCancelUrl,
	stashPendingAuthorization,
	stashPendingDeviceLink,
	takeConnectingMarker,
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
			toolSlug: null,
			clientName: "Obsidian",
			redirectVerified: false,
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

	// The parked query string is anyone's to write: no backend confirmation of
	// the redirect, no Cancel, or it is an open redirect.
	it("is null when the redirect was never confirmed as registered", () => {
		stashPendingAuthorization(SEARCH, null, "Google Antigravity");

		expect(pendingCancelUrl()).toBeNull();
	});

	it("sends access_denied back to the client with the original state", () => {
		stashPendingAuthorization(SEARCH, null, "Google Antigravity", true);

		expect(pendingCancelUrl()).toBe("https://app/cb?error=access_denied&state=xyz");
	});

	it("appends to a redirect that already has a query", () => {
		stashPendingAuthorization("?redirect_uri=https://app/cb%3Fa%3D1&state=xyz", null, null, true);

		expect(pendingCancelUrl()).toBe("https://app/cb?a=1&error=access_denied&state=xyz");
	});

	// RFC 9207 §2: an error response carries `iss` too.
	it("carries iss when the server sent one", () => {
		stashPendingAuthorization(
			"?redirect_uri=https://app/cb&state=xyz&iss=https%3A%2F%2Fmcp.engram.page",
			null,
			null,
			true,
		);

		expect(pendingCancelUrl()).toBe(
			"https://app/cb?error=access_denied&state=xyz&iss=https%3A%2F%2Fmcp.engram.page",
		);
	});

	it("omits state when the request carried none", () => {
		stashPendingAuthorization("?redirect_uri=https://app/cb", null, null, true);

		expect(pendingCancelUrl()).toBe("https://app/cb?error=access_denied");
	});

	// Without a redirect there is nowhere to report to, and inventing one is
	// how an open redirect gets built by accident.
	it("is null when the parked request has no redirect_uri", () => {
		stashPendingAuthorization("?client_id=cli&state=xyz", null, null, true);

		expect(pendingCancelUrl()).toBeNull();
	});

	it("refuses a non-http redirect", () => {
		stashPendingAuthorization("?redirect_uri=javascript:alert(1)&state=xyz", null, null, true);

		expect(pendingCancelUrl()).toBeNull();
	});
});

// The vault tab learns it was opened by consent from its own URL, not from a
// sessionStorage copy whose timing the browser does not promise.
describe("takeConnectingMarker", () => {
	beforeEach(() => {
		window.sessionStorage.clear();
	});

	it("keeps the marker and strips it from the URL", () => {
		window.history.replaceState(null, "", "/?connecting=1792000000000&client=chatgpt");
		takeConnectingMarker();
		expect(connecting()).toEqual({ since: 1_792_000_000_000, client: "chatgpt" });
		expect(window.location.search).toBe("");
	});

	// window.open copies the consent tab's sessionStorage into the new tab. Its
	// auto-open mark would skip the welcome note; its consent return is not ours.
	it("drops state copied from the consent tab", () => {
		window.sessionStorage.setItem("engram:auto-opened:my-vault", "1");
		window.sessionStorage.setItem("engram:consent-return", "/oauth/consent?x=1");
		window.history.replaceState(null, "", "/?connecting=1792000000000&client=chatgpt");
		takeConnectingMarker();
		expect(window.sessionStorage.getItem("engram:auto-opened:my-vault")).toBeNull();
		expect(window.sessionStorage.getItem("engram:consent-return")).toBeNull();
	});

	it("leaves a tab without the marker alone", () => {
		window.history.replaceState(null, "", "/?folder=Notes");
		takeConnectingMarker();
		expect(connecting()).toBeNull();
		expect(window.location.search).toBe("?folder=Notes");
	});

	it("builds the marked URL", () => {
		expect(connectingUrl("/", "chatgpt", 5)).toBe("/?connecting=5&client=chatgpt");
		expect(connectingUrl("/", null, 5)).toBe("/?connecting=5");
	});
});
