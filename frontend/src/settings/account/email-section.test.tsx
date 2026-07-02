import { isReverificationCancelledError } from "@clerk/react/errors";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { EmailSection } from "./email-section";
import { makeUser } from "./section-test-helpers";

const newEmail = {
	id: "eml_2",
	emailAddress: "new@example.com",
	prepareVerification: vi.fn().mockResolvedValue({}),
	attemptVerification: vi.fn().mockResolvedValue({}),
};

function twoEmailUser() {
	return makeUser({
		createEmailAddress: vi.fn().mockResolvedValue(newEmail),
		emailAddresses: [
			{
				id: "eml_1",
				emailAddress: "ada@example.com",
				verification: { status: "verified" },
				destroy: vi.fn().mockResolvedValue({}),
			},
			{
				id: "eml_2b",
				emailAddress: "second@example.com",
				verification: { status: "verified" },
				destroy: vi.fn().mockResolvedValue({}),
			},
		],
	});
}

let user = twoEmailUser();

vi.mock("@clerk/react", () => ({
	useUser: () => ({ user, isLoaded: true }),
	useReverification: (fn: unknown) => fn,
}));
vi.mock("@clerk/react/errors", () => ({
	isClerkAPIResponseError: () => false,
	isReverificationCancelledError: vi.fn(() => false),
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

describe("EmailSection", () => {
	beforeEach(() => {
		vi.clearAllMocks();
		vi.mocked(isReverificationCancelledError).mockReturnValue(false);
		user = twoEmailUser();
	});

	it("lists existing emails", () => {
		render(<EmailSection />);
		expect(screen.getByText("ada@example.com")).toBeInTheDocument();
	});

	it("adds an email and prepares verification", async () => {
		render(<EmailSection />);
		fireEvent.change(screen.getByLabelText(/add email/iu), {
			target: { value: "new@example.com" },
		});
		fireEvent.click(screen.getByRole("button", { name: /^add$/iu }));
		await waitFor(() =>
			expect(user.createEmailAddress).toHaveBeenCalledWith({ email: "new@example.com" }),
		);
		await waitFor(() =>
			expect(newEmail.prepareVerification).toHaveBeenCalledWith({ strategy: "email_code" }),
		);
	});

	it("verifies the new email with a code", async () => {
		render(<EmailSection />);
		fireEvent.change(screen.getByLabelText(/add email/iu), {
			target: { value: "new@example.com" },
		});
		fireEvent.click(screen.getByRole("button", { name: /^add$/iu }));
		await screen.findByLabelText(/verification code/iu);
		fireEvent.change(screen.getByLabelText(/verification code/iu), { target: { value: "123456" } });
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));
		await waitFor(() =>
			expect(newEmail.attemptVerification).toHaveBeenCalledWith({ code: "123456" }),
		);
	});

	it("removes an email via destroy and reloads the user", async () => {
		render(<EmailSection />);
		fireEvent.click(screen.getByRole("button", { name: /remove ada@example.com/iu }));
		await waitFor(() => expect(user.emailAddresses[0]!.destroy).toHaveBeenCalled());
		await waitFor(() => expect(user.reload).toHaveBeenCalled());
	});

	it("disables Remove when only one email address remains", () => {
		user = makeUser({
			emailAddresses: [
				{
					id: "eml_1",
					emailAddress: "ada@example.com",
					verification: { status: "verified" },
					destroy: vi.fn(),
				},
			],
		});
		render(<EmailSection />);
		expect(screen.getByRole("button", { name: /remove ada@example.com/iu })).toBeDisabled();
	});
});
