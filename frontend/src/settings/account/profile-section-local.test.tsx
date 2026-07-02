import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ProfileSectionLocal } from "./profile-section-local";

const { updateMutate } = vi.hoisted(() => ({
	updateMutate: vi.fn(),
}));

const meData = { id: 1, email: "me@example.com", role: "member", display_name: "Old" };

vi.mock("../../api/queries", () => ({
	useMe: () => ({ data: meData }),
	useUpdateProfile: () => ({ mutateAsync: updateMutate, isPending: false }),
}));

vi.mock("sonner", () => ({
	toast: { success: vi.fn(), error: vi.fn() },
}));

function wrap(ui: React.ReactNode) {
	const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return render(<QueryClientProvider client={qc}>{ui}</QueryClientProvider>);
}

beforeEach(() => {
	updateMutate.mockReset();
	(toast.success as ReturnType<typeof vi.fn>).mockReset();
	(toast.error as ReturnType<typeof vi.fn>).mockReset();
});

describe("ProfileSectionLocal", () => {
	it("shows current display_name and submits new value", async () => {
		updateMutate.mockResolvedValueOnce({ user: { display_name: "Sam" } });
		wrap(<ProfileSectionLocal />);
		const input = screen.getByLabelText(/display name/iu) as HTMLInputElement;
		expect(input.value).toBe("Old");

		fireEvent.change(input, { target: { value: "Sam" } });
		fireEvent.click(screen.getByRole("button", { name: /save/iu }));

		await waitFor(() => expect(updateMutate).toHaveBeenCalledWith({ display_name: "Sam" }));
		await waitFor(() => expect(toast.success).toHaveBeenCalled());
	});

	it("shows an error toast when the API rejects", async () => {
		updateMutate.mockRejectedValueOnce(new Error("validation_failed"));
		wrap(<ProfileSectionLocal />);
		const input = screen.getByLabelText(/display name/iu) as HTMLInputElement;
		fireEvent.change(input, { target: { value: "Sam" } });
		fireEvent.click(screen.getByRole("button", { name: /save/iu }));

		await waitFor(() =>
			expect(toast.error).toHaveBeenCalledWith(expect.stringMatching(/validation_failed/iu)),
		);
	});
});
