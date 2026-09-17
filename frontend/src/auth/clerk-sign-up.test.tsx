import { render } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import ClerkSignUp from "./clerk-sign-up";

const { signUpProps } = vi.hoisted(() => ({ signUpProps: vi.fn() }));
vi.mock("@clerk/react", () => ({
	SignUp: (props: Record<string, unknown>) => {
		signUpProps(props);
		return null;
	},
}));

const CONSENT = "/oauth/consent?client_id=abc&state=xyz";

function propsFor(returnTo: string): Record<string, unknown> {
	signUpProps.mockClear();
	render(<ClerkSignUp returnTo={returnTo} />);
	return signUpProps.mock.calls[0]?.[0] ?? {};
}

describe("ClerkSignUp", () => {
	// The whole point: a user with NO account signs up INSIDE the OAuth flow.
	// Hardcoding "/" here dropped the authorization request on the floor —
	// the consent page never rendered, so nothing was ever parked to resume.
	it("lands a finished signup on the destination that sent them here", () => {
		expect(propsFor(CONSENT)).toMatchObject({ forceRedirectUrl: CONSENT });
	});

	// The mirror of the bug being fixed. Someone who clicks "Sign in" from here
	// must not lose the destination on the way back.
	it("carries the destination on the sign-in cross-link", () => {
		expect(propsFor(CONSENT)).toMatchObject({
			signInUrl: "/sign-in?return_to=%2Foauth%2Fconsent%3Fclient_id%3Dabc%26state%3Dxyz",
		});
	});

	it("uses bare routes for an ordinary signup", () => {
		expect(propsFor("/")).toMatchObject({ forceRedirectUrl: "/", signInUrl: "/sign-in" });
	});
});
