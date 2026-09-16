import { beforeEach, describe, expect, it } from "vitest";
import {
	clearPendingAuthorization,
	peekPendingAuthorization,
	stashPendingAuthorization,
} from "./pending-authorization";

const SEARCH = "?client_id=cli&redirect_uri=https://app/cb&state=xyz";

describe("pending authorization stash", () => {
	beforeEach(() => {
		window.sessionStorage.clear();
	});

	it("round-trips the consent URL and the tool slug", () => {
		stashPendingAuthorization(SEARCH, "antigravity");

		expect(peekPendingAuthorization()).toEqual({
			returnTo: `/oauth/consent${SEARCH}`,
			toolSlug: "antigravity",
		});
	});

	it("returns null when nothing is stashed", () => {
		expect(peekPendingAuthorization()).toBeNull();
	});

	// Unlike `takeCredential`, reading does NOT consume. Several call sites ask
	// where onboarding should land, and the first one to ask must not delete
	// the answer for the rest.
	it("peek does not consume the stash", () => {
		stashPendingAuthorization(SEARCH, null);

		expect(peekPendingAuthorization()).not.toBeNull();
		expect(peekPendingAuthorization()).not.toBeNull();
	});

	it("clear removes it", () => {
		stashPendingAuthorization(SEARCH, null);
		clearPendingAuthorization();

		expect(peekPendingAuthorization()).toBeNull();
	});

	it("carries a null slug for a client we cannot attribute", () => {
		stashPendingAuthorization(SEARCH, null);

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
