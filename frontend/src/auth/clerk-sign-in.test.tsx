import { render, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import ClerkSignIn from "./clerk-sign-in";

const navigate = vi.fn();

vi.mock("react-router", async () => {
	const actual = await vi.importActual<typeof import("react-router")>("react-router");
	return { ...actual, useNavigate: () => navigate };
});

const useSignInMock = vi.fn();

vi.mock("@clerk/react", () => ({
	SignIn: ({ forceRedirectUrl }: { forceRedirectUrl: string }) => (
		<div data-testid="clerk-signin">{forceRedirectUrl}</div>
	),
}));

vi.mock("@clerk/react/legacy", () => ({
	useSignIn: () => useSignInMock(),
}));

function renderAt(returnTo = "/") {
	return render(
		<MemoryRouter>
			<ClerkSignIn returnTo={returnTo} />
		</MemoryRouter>,
	);
}

describe("ClerkSignIn waitlist redirect", () => {
	beforeEach(() => {
		navigate.mockReset();
		useSignInMock.mockReset();
	});

	it("navigates to /waitlist when OAuth verification reports sign_up_restricted_waitlist", async () => {
		useSignInMock.mockReturnValue({
			isLoaded: true,
			signIn: {
				firstFactorVerification: {
					status: "verified",
					strategy: "oauth_google",
					error: { code: "sign_up_restricted_waitlist" },
				},
			},
		});

		renderAt();

		await waitFor(() => expect(navigate).toHaveBeenCalledWith("/waitlist", { replace: true }));
	});

	it("does not navigate before Clerk has loaded", () => {
		useSignInMock.mockReturnValue({
			isLoaded: false,
			signIn: {
				firstFactorVerification: {
					error: { code: "sign_up_restricted_waitlist" },
				},
			},
		});

		renderAt();

		expect(navigate).not.toHaveBeenCalled();
	});

	it("does not navigate when there is no verification error", () => {
		useSignInMock.mockReturnValue({
			isLoaded: true,
			signIn: { firstFactorVerification: { status: "verified" } },
		});

		renderAt();

		expect(navigate).not.toHaveBeenCalled();
	});

	it("does not navigate on unrelated verification errors", () => {
		useSignInMock.mockReturnValue({
			isLoaded: true,
			signIn: {
				firstFactorVerification: {
					error: { code: "oauth_access_denied" },
				},
			},
		});

		renderAt();

		expect(navigate).not.toHaveBeenCalled();
	});

	it("renders the Clerk SignIn component with forceRedirectUrl", () => {
		useSignInMock.mockReturnValue({ isLoaded: true, signIn: null });

		const { getByTestId } = renderAt("/dashboard");

		expect(getByTestId("clerk-signin").textContent).toBe("/dashboard");
	});
});
