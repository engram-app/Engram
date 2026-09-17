import { render } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import ClerkSignIn from "./clerk-sign-in";

const { signInProps } = vi.hoisted(() => ({ signInProps: vi.fn() }));
vi.mock("@clerk/react", () => ({
	SignIn: (props: Record<string, unknown>) => {
		signInProps(props);
		return null;
	},
}));

const CONSENT = "/oauth/consent?client_id=abc&state=xyz";

function propsFor(returnTo: string): Record<string, unknown> {
	signInProps.mockClear();
	render(<ClerkSignIn returnTo={returnTo} />);
	return signInProps.mock.calls[0]?.[0] ?? {};
}

describe("ClerkSignIn", () => {
	it("lands a finished sign-in on the destination that sent them here", () => {
		expect(propsFor(CONSENT)).toMatchObject({ forceRedirectUrl: CONSENT });
	});

	// `ClerkProvider` sets a BARE `signUpUrl`, so the widget's "Sign up" link
	// dropped the destination before the user ever reached /sign-up. That is
	// where an MCP-first signup lost its authorization request.
	it("carries the destination on the sign-up cross-link", () => {
		expect(propsFor(CONSENT)).toMatchObject({
			signUpUrl: "/sign-up?return_to=%2Foauth%2Fconsent%3Fclient_id%3Dabc%26state%3Dxyz",
		});
	});

	it("uses bare routes for an ordinary sign-in", () => {
		expect(propsFor("/")).toMatchObject({ forceRedirectUrl: "/", signUpUrl: "/sign-up" });
	});
});
