import { beforeEach, describe, expect, it } from "vitest";
import {
	clearPendingAuthorization,
	peekPendingAuthorization,
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
		});
	});

	// The plugin-first signup: Obsidian opens /link, the user signs up there,
	// and the device code has to survive the wizard the same way a consent
	// request does.
	it("parks a device-link code and returns to /link with it", () => {
		expect(stashPendingDeviceLink("ENGR-7X4K")).toBe(true);

		expect(peekPendingAuthorization()).toEqual({
			returnTo: "/link?code=ENGR-7X4K",
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

		it("drops malformed JSON rather than throwing", () => {
			window.sessionStorage.setItem("engram:pending-oauth", "{not json");

			expect(peekPendingAuthorization()).toBeNull();
		});
	});
});
