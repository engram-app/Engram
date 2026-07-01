import { describe, expect, it } from "vitest";
import { toRelativeUrl } from "./clerk-auth-provider";

describe("toRelativeUrl", () => {
	const origin = window.location.origin;

	it("strips same-origin absolute URLs to path", () => {
		expect(toRelativeUrl(`${origin}/`)).toBe("/");
		expect(toRelativeUrl(`${origin}/dashboard`)).toBe("/dashboard");
	});

	it("preserves search and hash on same-origin URLs", () => {
		expect(toRelativeUrl(`${origin}/x?a=1#b`)).toBe("/x?a=1#b");
	});

	it("passes off-origin URLs through untouched (full-page nav)", () => {
		const off = "https://accounts.google.com/oauth/x";
		expect(toRelativeUrl(off)).toBe(off);
	});

	it("passes already-relative paths through untouched", () => {
		expect(toRelativeUrl("/sign-in")).toBe("/sign-in");
		expect(toRelativeUrl("/onboard/billing?step=2")).toBe("/onboard/billing?step=2");
	});
});
