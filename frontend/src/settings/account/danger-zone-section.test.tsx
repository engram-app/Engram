import { isReverificationCancelledError } from "@clerk/react/errors";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { DangerZoneSection } from "./danger-zone-section";
import { makeUser } from "./section-test-helpers";

// The live Clerk singleton: `user` goes null once a sign-out lands.
const clerk: { user: object | null; signOut: () => Promise<void> } = {
	user: {},
	signOut: vi.fn().mockResolvedValue(undefined),
};
const logout = vi.fn(() => {
	clerk.user = null;
	return Promise.resolve();
});
let user = makeUser();
vi.mock("@clerk/react", () => ({
	useUser: () => ({ user, isLoaded: true }),
	useReverification: (fn: unknown) => fn,
	useClerk: () => clerk,
}));
vi.mock("../../auth/use-auth-adapter", () => ({ useAuthAdapter: () => ({ logout }) }));
vi.mock("@clerk/react/errors", () => ({
	isClerkAPIResponseError: () => false,
	isReverificationCancelledError: vi.fn(() => false),
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));
const submitFeedback = vi.fn().mockResolvedValue({ status: "ok" });
vi.mock("../../api/queries", () => ({
	useSubmitFeedback: () => ({ mutateAsync: submitFeedback, isPending: false }),
}));

function openDialog() {
	fireEvent.click(screen.getByRole("button", { name: /^delete account$/iu }));
}

function fillForm({ reason = true, detail = "too slow on my phone" } = {}) {
	openDialog();
	if (reason) {
		fireEvent.click(screen.getByRole("radio", { name: /switched to another tool/iu }));
	}
	fireEvent.change(screen.getByLabelText(/tell us more/iu), { target: { value: detail } });
	fireEvent.change(screen.getByLabelText(/type .*delete my account/iu), {
		target: { value: "delete my account" },
	});
}

describe("DangerZoneSection", () => {
	beforeEach(() => {
		vi.clearAllMocks();
		user = makeUser();
		clerk.user = {};
		vi.mocked(isReverificationCancelledError).mockReturnValue(false);
	});

	it("keeps the reason form in a dialog until Delete account is clicked", () => {
		render(<DangerZoneSection />);
		expect(screen.queryByLabelText(/tell us more/iu)).not.toBeInTheDocument();
		openDialog();
		expect(screen.getByRole("dialog", { name: /delete your account/iu })).toBeInTheDocument();
		expect(screen.getByLabelText(/tell us more/iu)).toBeInTheDocument();
	});

	it("keeps delete disabled until the confirmation phrase matches", () => {
		render(<DangerZoneSection />);
		openDialog();
		const btn = screen.getByRole("button", { name: /delete my account/iu });
		expect(btn).toBeDisabled();
		fireEvent.click(screen.getByRole("radio", { name: /switched to another tool/iu }));
		fireEvent.change(screen.getByLabelText(/tell us more/iu), { target: { value: "slow" } });
		expect(btn).toBeDisabled();
		fireEvent.change(screen.getByLabelText(/type .*delete my account/iu), {
			target: { value: "delete my account" },
		});
		expect(btn).toBeEnabled();
	});

	it("deletes with no answer and sends no feedback", async () => {
		render(<DangerZoneSection />);
		openDialog();
		fireEvent.change(screen.getByLabelText(/type .*delete my account/iu), {
			target: { value: "delete my account" },
		});
		fireEvent.click(screen.getByRole("button", { name: /delete my account/iu }));
		await waitFor(() => expect(user.delete).toHaveBeenCalled());
		expect(submitFeedback).not.toHaveBeenCalled();
	});

	it("sends the text alone when no reason is picked", async () => {
		render(<DangerZoneSection />);
		fillForm({ reason: false, detail: " moving on " });
		fireEvent.click(screen.getByRole("button", { name: /delete my account/iu }));
		await waitFor(() => expect(user.delete).toHaveBeenCalled());
		expect(submitFeedback).toHaveBeenCalledWith({ kind: "delete_account", detail: "moving on" });
	});

	it("does not wait on a hung feedback request", async () => {
		vi.useFakeTimers({ shouldAdvanceTime: true });
		submitFeedback.mockReturnValueOnce(new Promise(() => undefined));
		render(<DangerZoneSection />);
		fillForm();
		fireEvent.click(screen.getByRole("button", { name: /delete my account/iu }));
		await vi.advanceTimersByTimeAsync(3000);
		await waitFor(() => expect(user.delete).toHaveBeenCalled());
		vi.useRealTimers();
	});

	it("disables Delete account while a delete is in flight", async () => {
		user = makeUser({ delete: vi.fn(() => new Promise(() => undefined)) });
		render(<DangerZoneSection />);
		fillForm();
		fireEvent.click(screen.getByRole("button", { name: /delete my account/iu }));
		await waitFor(() => expect(user.delete).toHaveBeenCalled());
		expect(screen.getByRole("button", { name: /^delete account$/iu })).toBeDisabled();
	});

	it("sends the reason before deleting, then signs out", async () => {
		render(<DangerZoneSection />);
		fillForm({ detail: "  too slow on my phone  " });
		fireEvent.click(screen.getByRole("button", { name: /delete my account/iu }));
		await waitFor(() => expect(user.delete).toHaveBeenCalled());
		expect(submitFeedback).toHaveBeenCalledWith({
			kind: "delete_account",
			reason: "switched_tool",
			detail: "too slow on my phone",
		});
		expect(submitFeedback.mock.invocationCallOrder[0]).toBeLessThan(
			vi.mocked(user.delete).mock.invocationCallOrder[0] ?? 0,
		);
		await waitFor(() => expect(logout).toHaveBeenCalledTimes(1));
	});

	it("still deletes when sending the reason fails", async () => {
		submitFeedback.mockRejectedValueOnce(new Error("offline"));
		render(<DangerZoneSection />);
		fillForm();
		fireEvent.click(screen.getByRole("button", { name: /delete my account/iu }));
		await waitFor(() => expect(user.delete).toHaveBeenCalled());
	});

	it("does not toast an error when reverification is cancelled", async () => {
		user = makeUser({ delete: vi.fn().mockRejectedValue(new Error("cancelled")) });
		vi.mocked(isReverificationCancelledError).mockReturnValue(true);
		render(<DangerZoneSection />);
		fillForm();
		fireEvent.click(screen.getByRole("button", { name: /delete my account/iu }));
		await waitFor(() => expect(user.delete).toHaveBeenCalled());
		expect(toast.error).not.toHaveBeenCalled();
		expect(logout).not.toHaveBeenCalled();
	});

	it("still leaves for sign-in when the sign-out after a delete fails", async () => {
		// The shared logout swallows a failed or timed-out signOut into a toast,
		// so Clerk still holds the (deleted) user.
		logout.mockImplementationOnce(() => Promise.resolve());
		const assign = vi.fn();
		vi.spyOn(window, "location", "get").mockReturnValue({ ...window.location, assign });
		try {
			render(<DangerZoneSection />);
			fillForm();
			fireEvent.click(screen.getByRole("button", { name: /delete my account/iu }));

			await waitFor(() => expect(assign).toHaveBeenCalledWith("/sign-in"));
			expect(toast.error).not.toHaveBeenCalled();
		} finally {
			vi.restoreAllMocks();
		}
	});

	it("does not reload when the sign-out lands", async () => {
		const assign = vi.fn();
		vi.spyOn(window, "location", "get").mockReturnValue({ ...window.location, assign });
		try {
			render(<DangerZoneSection />);
			fillForm();
			fireEvent.click(screen.getByRole("button", { name: /delete my account/iu }));

			await waitFor(() => expect(logout).toHaveBeenCalledTimes(1));
			await new Promise((resolve) => setTimeout(resolve, 0));
			expect(assign).not.toHaveBeenCalled();
		} finally {
			vi.restoreAllMocks();
		}
	});
});
