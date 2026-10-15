import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { PrivacySection } from "./privacy-section";

const { updateMutate, me } = vi.hoisted(() => ({
	updateMutate: vi.fn(),
	me: { current: { analytics_opt_out: false } as { analytics_opt_out: boolean } | undefined },
}));

vi.mock("../../api/queries", () => ({
	useMe: () => ({ data: me.current }),
	useUpdateProfile: () => ({ mutateAsync: updateMutate, isPending: false }),
}));

vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

beforeEach(() => {
	updateMutate.mockReset();
	vi.mocked(toast.error).mockReset();
	me.current = { analytics_opt_out: false };
});

const checkbox = () => screen.getByRole("checkbox", { name: "Share usage analytics" });

describe("PrivacySection", () => {
	it("is checked while the user shares analytics", () => {
		render(<PrivacySection />);
		expect(screen.getByRole("heading", { name: "Privacy" })).toBeInTheDocument();
		expect(checkbox()).toBeChecked();
	});

	it("is unchecked for a user who opted out", () => {
		me.current = { analytics_opt_out: true };
		render(<PrivacySection />);
		expect(checkbox()).not.toBeChecked();
	});

	it("unchecking opts the user out", async () => {
		updateMutate.mockResolvedValueOnce({});
		render(<PrivacySection />);
		fireEvent.click(checkbox());
		await waitFor(() => expect(updateMutate).toHaveBeenCalledWith({ analytics_opt_out: true }));
	});

	it("checking opts the user back in", async () => {
		me.current = { analytics_opt_out: true };
		updateMutate.mockResolvedValueOnce({});
		render(<PrivacySection />);
		fireEvent.click(checkbox());
		await waitFor(() => expect(updateMutate).toHaveBeenCalledWith({ analytics_opt_out: false }));
	});

	it("shows an error toast when the save fails", async () => {
		updateMutate.mockRejectedValueOnce(new Error("network"));
		render(<PrivacySection />);
		fireEvent.click(checkbox());
		await waitFor(() => expect(toast.error).toHaveBeenCalled());
	});

	it("is disabled until the account has loaded", () => {
		me.current = undefined;
		render(<PrivacySection />);
		expect(checkbox()).toBeDisabled();
	});
});
