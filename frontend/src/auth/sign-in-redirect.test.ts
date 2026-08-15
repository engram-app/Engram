import { describe, expect, it } from "vitest";
import { signInRedirectTarget } from "./sign-in-redirect";

describe("signInRedirectTarget", () => {
	it("redirects to bare sign-in from the home path (no return_to round-trip)", () => {
		expect(signInRedirectTarget({ pathname: "/", search: "", hash: "" })).toBe("/sign-in");
	});

	it("preserves the original path as an encoded return_to", () => {
		expect(signInRedirectTarget({ pathname: "/note/abc", search: "", hash: "" })).toBe(
			"/sign-in?return_to=%2Fnote%2Fabc",
		);
	});

	it("includes search and hash in the return_to", () => {
		expect(
			signInRedirectTarget({ pathname: "/settings", search: "?tab=billing", hash: "#plan" }),
		).toBe("/sign-in?return_to=%2Fsettings%3Ftab%3Dbilling%23plan");
	});
});

describe("credentials never ride the return_to", () => {
	// The plugin sends users to /link?code=ENGR-7X4K. A signed-out arrival is
	// redirected first, and return_to is handed to Clerk as forceRedirectUrl —
	// so without stripping, the single-use device code sits in the address bar
	// and in history for the whole login round trip, and goes to a third party
	// on the way. The /link page's own address-bar scrub runs far too late to
	// matter here: it only fires once the user is already signed in.
	it("strips a device code from the preserved destination", () => {
		const target = signInRedirectTarget({
			pathname: "/link",
			search: "?code=ENGR-7X4K",
			hash: "",
		});

		expect(target).not.toContain("ENGR");
		expect(target).not.toContain("code");
		expect(decodeURIComponent(target)).toContain("/link");
	});

	// Same class: the reset token is the credential, and the page itself calls
	// it that.
	it("strips a password-reset token", () => {
		const target = signInRedirectTarget({
			pathname: "/reset-password",
			search: "?token=abc123secret",
			hash: "",
		});

		expect(target).not.toContain("abc123secret");
		expect(decodeURIComponent(target)).toContain("/reset-password");
	});

	// Navigation state is not a credential — dropping it would lose the user's
	// place for no gain.
	it("keeps ordinary params", () => {
		const target = signInRedirectTarget({
			pathname: "/link",
			search: "?code=SECRET&ref=newsletter",
			hash: "#top",
		});

		const decoded = decodeURIComponent(target);
		expect(decoded).toContain("ref=newsletter");
		expect(decoded).toContain("#top");
		expect(decoded).not.toContain("SECRET");
	});
});
