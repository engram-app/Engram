import { isReverificationCancelledError } from "@clerk/react/errors";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { DangerZoneSection } from "./danger-zone-section";
import { makeUser } from "./section-test-helpers";

const signOut = vi.fn().mockResolvedValue({});
let user = makeUser();
vi.mock("@clerk/react", () => ({
	useUser: () => ({ user, isLoaded: true }),
	useReverification: (fn: unknown) => fn,
	useClerk: () => ({ signOut }),
}));
vi.mock("@clerk/react/errors", () => ({
	isClerkAPIResponseError: () => false,
	isReverificationCancelledError: vi.fn(() => false),
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));
const submitFeedback = vi.fn().mockResolvedValue({ status: "ok" });
vi.mock("../../api/queries", () => ({
	useSubmitFeedback: () => ({ mutateAsync: submitFeedback, isPending: false }),
}));

function fillForm({ reason = true, detail = "too slow on my phone" } = {}) {
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
		vi.mocked(isReverificationCancelledError).mockReturnValue(false);
	});

	it("keeps delete disabled until the confirmation phrase matches", () => {
		render(<DangerZoneSection />);
		const btn = screen.getByRole("button", { name: /delete my account/iu });
		expect(btn).toBeDisabled();
		fillForm();
		expect(btn).toBeEnabled();
	});

	it("keeps delete disabled without a reason", () => {
		render(<DangerZoneSection />);
		fillForm({ reason: false });
		expect(screen.getByRole("button", { name: /delete my account/iu })).toBeDisabled();
	});

	it("keeps delete disabled when the detail is only whitespace", () => {
		render(<DangerZoneSection />);
		fillForm({ detail: "   " });
		expect(screen.getByRole("button", { name: /delete my account/iu })).toBeDisabled();
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
		await waitFor(() => expect(signOut).toHaveBeenCalledWith({ redirectUrl: "/sign-in" }));
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
		expect(signOut).not.toHaveBeenCalled();
	});
});
