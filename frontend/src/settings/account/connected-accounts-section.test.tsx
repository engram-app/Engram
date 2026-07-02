import { isReverificationCancelledError } from "@clerk/react/errors";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ConnectedAccountsSection } from "./connected-accounts-section";
import { makeUser } from "./section-test-helpers";

const googleAcct = {
	id: "ext_1",
	provider: "google",
	emailAddress: "ada@gmail.com",
	destroy: vi.fn().mockResolvedValue({}),
};
let user = makeUser({ externalAccounts: [googleAcct] });

vi.mock("@clerk/react", () => ({
	useUser: () => ({ user, isLoaded: true }),
	useReverification: (fn: unknown) => fn,
}));
vi.mock("@clerk/react/errors", () => ({
	isClerkAPIResponseError: () => false,
	isReverificationCancelledError: vi.fn(() => false),
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

describe("ConnectedAccountsSection", () => {
	beforeEach(() => {
		vi.clearAllMocks();
		user = makeUser({ externalAccounts: [googleAcct] });
		vi.mocked(isReverificationCancelledError).mockReturnValue(false);
	});

	it("lists connected accounts and disconnects via destroy", async () => {
		render(<ConnectedAccountsSection providers={["oauth_google", "oauth_github"]} />);
		expect(screen.getByText(/ada@gmail.com/iu)).toBeInTheDocument();
		fireEvent.click(screen.getByRole("button", { name: /disconnect google/iu }));
		await waitFor(() => expect(googleAcct.destroy).toHaveBeenCalled());
		await waitFor(() => expect(user.reload).toHaveBeenCalled());
	});

	it('shows a "Connected" fallback when the provider returned no email or username', () => {
		const bare = {
			id: "ext_2",
			provider: "github",
			emailAddress: "",
			username: null,
			destroy: vi.fn(),
		};
		user = makeUser({ externalAccounts: [bare] });
		render(<ConnectedAccountsSection providers={["oauth_github"]} />);
		expect(screen.getByText("GitHub")).toBeInTheDocument();
		expect(screen.getByText("Connected")).toBeInTheDocument();
		expect(screen.queryByText(/—/u)).not.toBeInTheDocument();
	});

	it("connects a new provider via createExternalAccount", async () => {
		render(<ConnectedAccountsSection providers={["oauth_github"]} />);
		fireEvent.click(screen.getByRole("button", { name: /connect github/iu }));
		await waitFor(() =>
			expect(user.createExternalAccount).toHaveBeenCalledWith(
				expect.objectContaining({ strategy: "oauth_github" }),
			),
		);
	});
});
