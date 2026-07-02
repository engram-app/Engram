import { isReverificationCancelledError } from "@clerk/react/errors";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { EmailSection } from "./email-section";
import { makeUser } from "./section-test-helpers";

function makeVerifiableEmail(id: string, address: string) {
	return {
		id,
		emailAddress: address,
		prepareVerification: vi.fn().mockResolvedValue({}),
		attemptVerification: vi.fn().mockResolvedValue({}),
	};
}

let user = makeUser();

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
		user = makeUser();
	});

	it("shows the current primary email and no multi-email management", () => {
		render(<EmailSection />);
		expect(screen.getByText("ada@example.com")).toBeInTheDocument();
		expect(screen.queryByLabelText(/add email/iu)).not.toBeInTheDocument();
		expect(screen.getByLabelText(/new email/iu)).toBeInTheDocument();
	});

	it("changes to a brand-new email: create → verify → set primary → remove old", async () => {
		const created = makeVerifiableEmail("eml_2", "new@example.com");
		user = makeUser({ createEmailAddress: vi.fn().mockResolvedValue(created) });
		render(<EmailSection />);

		fireEvent.change(screen.getByLabelText(/new email/iu), {
			target: { value: "new@example.com" },
		});
		fireEvent.click(screen.getByRole("button", { name: /update email/iu }));

		await waitFor(() =>
			expect(user.createEmailAddress).toHaveBeenCalledWith({ email: "new@example.com" }),
		);
		await waitFor(() =>
			expect(created.prepareVerification).toHaveBeenCalledWith({ strategy: "email_code" }),
		);

		fireEvent.change(await screen.findByLabelText(/verification code/iu), {
			target: { value: "123456" },
		});
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));

		await waitFor(() =>
			expect(created.attemptVerification).toHaveBeenCalledWith({ code: "123456" }),
		);
		await waitFor(() =>
			expect(user.update).toHaveBeenCalledWith({ primaryEmailAddressId: "eml_2" }),
		);
		// old primary is removed so the account ends with a single email
		await waitFor(() => expect(user.emailAddresses[0]!.destroy).toHaveBeenCalled());
		await waitFor(() => expect(user.reload).toHaveBeenCalled());
		expect(toast.success).toHaveBeenCalledWith("Email updated");
	});

	it("reuses an already-verified address on the account without a code step", async () => {
		const secondary = {
			id: "eml_2b",
			emailAddress: "second@example.com",
			verification: { status: "verified" },
			destroy: vi.fn().mockResolvedValue({}),
			prepareVerification: vi.fn(),
			attemptVerification: vi.fn(),
		};
		user = makeUser({
			emailAddresses: [
				{
					id: "eml_1",
					emailAddress: "ada@example.com",
					verification: { status: "verified" },
					destroy: vi.fn().mockResolvedValue({}),
				},
				secondary,
			],
		});
		render(<EmailSection />);

		fireEvent.change(screen.getByLabelText(/new email/iu), {
			target: { value: "second@example.com" },
		});
		fireEvent.click(screen.getByRole("button", { name: /update email/iu }));

		await waitFor(() =>
			expect(user.update).toHaveBeenCalledWith({ primaryEmailAddressId: "eml_2b" }),
		);
		expect(screen.queryByLabelText(/verification code/iu)).not.toBeInTheDocument();
		await waitFor(() => expect(user.emailAddresses[0]!.destroy).toHaveBeenCalled());
		expect(user.createEmailAddress).not.toHaveBeenCalled();
	});

	it("re-sends a code for an existing but unverified address (skips create)", async () => {
		const secondary = {
			id: "eml_2b",
			emailAddress: "second@example.com",
			verification: { status: "unverified" },
			destroy: vi.fn().mockResolvedValue({}),
			prepareVerification: vi.fn().mockResolvedValue({}),
			attemptVerification: vi.fn().mockResolvedValue({}),
		};
		user = makeUser({
			emailAddresses: [
				{
					id: "eml_1",
					emailAddress: "ada@example.com",
					verification: { status: "verified" },
					destroy: vi.fn().mockResolvedValue({}),
				},
				secondary,
			],
		});
		render(<EmailSection />);

		fireEvent.change(screen.getByLabelText(/new email/iu), {
			target: { value: "second@example.com" },
		});
		fireEvent.click(screen.getByRole("button", { name: /update email/iu }));

		await waitFor(() =>
			expect(secondary.prepareVerification).toHaveBeenCalledWith({ strategy: "email_code" }),
		);
		expect(user.createEmailAddress).not.toHaveBeenCalled();
		await screen.findByLabelText(/verification code/iu);
	});

	it("rejects changing to the address that is already primary", async () => {
		render(<EmailSection />);
		fireEvent.change(screen.getByLabelText(/new email/iu), {
			target: { value: "ada@example.com" },
		});
		fireEvent.click(screen.getByRole("button", { name: /update email/iu }));

		await waitFor(() => expect(toast.error).toHaveBeenCalledWith("That's already your email"));
		expect(user.createEmailAddress).not.toHaveBeenCalled();
	});

	it("shows 'Invalid code' only when the code itself is rejected", async () => {
		const created = {
			id: "eml_2",
			emailAddress: "new@example.com",
			prepareVerification: vi.fn().mockResolvedValue({}),
			attemptVerification: vi.fn().mockRejectedValue(new Error("bad code")),
		};
		user = makeUser({ createEmailAddress: vi.fn().mockResolvedValue(created) });
		render(<EmailSection />);
		fireEvent.change(screen.getByLabelText(/new email/iu), {
			target: { value: "new@example.com" },
		});
		fireEvent.click(screen.getByRole("button", { name: /update email/iu }));
		fireEvent.change(await screen.findByLabelText(/verification code/iu), {
			target: { value: "000000" },
		});
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));

		await waitFor(() => expect(toast.error).toHaveBeenCalledWith("Invalid code"));
		// The code failed, so the primary must NOT have changed.
		expect(user.update).not.toHaveBeenCalled();
	});

	it("reports a promotion failure (not 'Invalid code') when set-primary fails after the code verifies", async () => {
		const created = {
			id: "eml_2",
			emailAddress: "new@example.com",
			prepareVerification: vi.fn().mockResolvedValue({}),
			attemptVerification: vi.fn().mockResolvedValue({}),
		};
		user = makeUser({
			createEmailAddress: vi.fn().mockResolvedValue(created),
			update: vi.fn().mockRejectedValue(new Error("set-primary failed")),
		});
		render(<EmailSection />);
		fireEvent.change(screen.getByLabelText(/new email/iu), {
			target: { value: "new@example.com" },
		});
		fireEvent.click(screen.getByRole("button", { name: /update email/iu }));
		fireEvent.change(await screen.findByLabelText(/verification code/iu), {
			target: { value: "123456" },
		});
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));

		await waitFor(() => expect(created.attemptVerification).toHaveBeenCalled());
		await waitFor(() => expect(toast.error).toHaveBeenCalledWith("Could not update email"));
		expect(toast.error).not.toHaveBeenCalledWith("Invalid code");
	});

	it("still reports success when removing the old address fails after the primary changed", async () => {
		const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
		const created = {
			id: "eml_2",
			emailAddress: "new@example.com",
			prepareVerification: vi.fn().mockResolvedValue({}),
			attemptVerification: vi.fn().mockResolvedValue({}),
		};
		const oldPrimary = {
			id: "eml_1",
			emailAddress: "ada@example.com",
			verification: { status: "verified" },
			destroy: vi.fn().mockRejectedValue(new Error("cleanup failed")),
		};
		user = makeUser({
			emailAddresses: [oldPrimary],
			createEmailAddress: vi.fn().mockResolvedValue(created),
		});
		render(<EmailSection />);
		fireEvent.change(screen.getByLabelText(/new email/iu), {
			target: { value: "new@example.com" },
		});
		fireEvent.click(screen.getByRole("button", { name: /update email/iu }));
		fireEvent.change(await screen.findByLabelText(/verification code/iu), {
			target: { value: "123456" },
		});
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));

		// Primary switched, so the change succeeded despite the cleanup failure.
		await waitFor(() =>
			expect(user.update).toHaveBeenCalledWith({ primaryEmailAddressId: "eml_2" }),
		);
		await waitFor(() => expect(toast.success).toHaveBeenCalledWith("Email updated"));
		expect(toast.error).not.toHaveBeenCalled();
		consoleError.mockRestore();
	});
});
