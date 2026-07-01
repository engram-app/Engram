import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { toast } from "sonner";
import { isReverificationCancelledError } from "@clerk/react/errors";
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

import { DangerZoneSection } from "./danger-zone-section";

describe("DangerZoneSection", () => {
	beforeEach(() => {
		vi.clearAllMocks();
		user = makeUser();
		vi.mocked(isReverificationCancelledError).mockReturnValue(false);
	});

	it("keeps delete disabled until the confirmation phrase matches", () => {
		render(<DangerZoneSection />);
		const btn = screen.getByRole("button", { name: /delete my account/i });
		expect(btn).toBeDisabled();
		fireEvent.change(screen.getByLabelText(/type .*delete my account/i), {
			target: { value: "delete my account" },
		});
		expect(btn).toBeEnabled();
	});

	it("calls user.delete then signs out when confirmed", async () => {
		render(<DangerZoneSection />);
		fireEvent.change(screen.getByLabelText(/type .*delete my account/i), {
			target: { value: "delete my account" },
		});
		fireEvent.click(screen.getByRole("button", { name: /delete my account/i }));
		await waitFor(() => expect(user.delete).toHaveBeenCalled());
		await waitFor(() => expect(signOut).toHaveBeenCalledWith({ redirectUrl: "/sign-in" }));
	});

	it("does not toast an error when reverification is cancelled", async () => {
		user = makeUser({ delete: vi.fn().mockRejectedValue(new Error("cancelled")) });
		vi.mocked(isReverificationCancelledError).mockReturnValue(true);
		render(<DangerZoneSection />);
		fireEvent.change(screen.getByLabelText(/type .*delete my account/i), {
			target: { value: "delete my account" },
		});
		fireEvent.click(screen.getByRole("button", { name: /delete my account/i }));
		await waitFor(() => expect(user.delete).toHaveBeenCalled());
		expect(toast.error).not.toHaveBeenCalled();
		expect(signOut).not.toHaveBeenCalled();
	});
});
