import { isReverificationCancelledError } from "@clerk/react/errors";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { PasswordSection } from "./password-section";
import { makeUser } from "./section-test-helpers";

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

describe("PasswordSection", () => {
	beforeEach(() => {
		vi.clearAllMocks();
		user = makeUser();
		vi.mocked(isReverificationCancelledError).mockReturnValue(false);
	});

	it("changes password with current + new when passwordEnabled", async () => {
		render(<PasswordSection />);
		fireEvent.change(screen.getByLabelText(/current password/iu), { target: { value: "old" } });
		fireEvent.change(screen.getByLabelText(/^new password/iu), { target: { value: "newpass123" } });
		fireEvent.click(screen.getByRole("button", { name: /update password/iu }));
		await waitFor(() =>
			expect(user.updatePassword).toHaveBeenCalledWith({
				currentPassword: "old",
				newPassword: "newpass123",
				signOutOfOtherSessions: true,
			}),
		);
	});

	it("omits currentPassword when no password is set yet", async () => {
		user = makeUser({ passwordEnabled: false });
		render(<PasswordSection />);
		expect(screen.queryByLabelText(/current password/iu)).not.toBeInTheDocument();
		fireEvent.change(screen.getByLabelText(/^new password/iu), { target: { value: "newpass123" } });
		fireEvent.click(screen.getByRole("button", { name: /set password/iu }));
		await waitFor(() =>
			expect(user.updatePassword).toHaveBeenCalledWith({
				newPassword: "newpass123",
				signOutOfOtherSessions: true,
			}),
		);
	});

	it("does not toast an error when reverification is cancelled", async () => {
		user = makeUser({ updatePassword: vi.fn().mockRejectedValue(new Error("cancelled")) });
		vi.mocked(isReverificationCancelledError).mockReturnValue(true);
		render(<PasswordSection />);
		fireEvent.change(screen.getByLabelText(/current password/iu), { target: { value: "old" } });
		fireEvent.change(screen.getByLabelText(/^new password/iu), { target: { value: "newpass123" } });
		fireEvent.click(screen.getByRole("button", { name: /update password/iu }));
		await waitFor(() => expect(user.updatePassword).toHaveBeenCalled());
		expect(toast.error).not.toHaveBeenCalled();
	});
});
