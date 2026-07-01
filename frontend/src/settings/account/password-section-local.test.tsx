import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";

const { logout, apiPost, navigate } = vi.hoisted(() => ({
	logout: vi.fn().mockResolvedValue(undefined),
	apiPost: vi.fn().mockResolvedValue({ ok: true }),
	navigate: vi.fn(),
}));

vi.mock("../../auth/use-auth-adapter", () => ({
	useAuthAdapter: () => ({ logout }),
}));

vi.mock("../../api/client", () => ({
	api: { post: apiPost },
}));

vi.mock("react-router", () => ({ useNavigate: () => navigate }));

import { PasswordSectionLocal } from "./password-section-local";

beforeEach(() => {
	logout.mockReset().mockResolvedValue(undefined);
	apiPost.mockReset().mockResolvedValue({ ok: true });
	navigate.mockReset();
});

describe("PasswordSectionLocal", () => {
	it("blocks submit when new + confirm mismatch", async () => {
		render(<PasswordSectionLocal />);
		fireEvent.change(screen.getByLabelText(/current password/i), { target: { value: "old" } });
		fireEvent.change(screen.getByLabelText(/^new password$/i), { target: { value: "newpass12" } });
		fireEvent.change(screen.getByLabelText(/confirm new password/i), {
			target: { value: "different" },
		});
		fireEvent.click(screen.getByRole("button", { name: /change password/i }));

		expect(await screen.findByText(/passwords do not match/i)).toBeInTheDocument();
		expect(apiPost).not.toHaveBeenCalled();
	});

	it("submits, logs out, and redirects on success", async () => {
		render(<PasswordSectionLocal />);
		fireEvent.change(screen.getByLabelText(/current password/i), {
			target: { value: "oldpass12" },
		});
		fireEvent.change(screen.getByLabelText(/^new password$/i), { target: { value: "newpass12" } });
		fireEvent.change(screen.getByLabelText(/confirm new password/i), {
			target: { value: "newpass12" },
		});
		fireEvent.click(screen.getByRole("button", { name: /change password/i }));

		await waitFor(() =>
			expect(apiPost).toHaveBeenCalledWith("/auth/password/change", {
				old_password: "oldpass12",
				new_password: "newpass12",
			}),
		);
		await waitFor(() => expect(logout).toHaveBeenCalled());
		await waitFor(() => expect(navigate).toHaveBeenCalledWith("/sign-in"));
	});

	it("surfaces backend error and does not sign out", async () => {
		apiPost.mockReset().mockRejectedValueOnce(new Error("invalid_password"));
		render(<PasswordSectionLocal />);
		fireEvent.change(screen.getByLabelText(/current password/i), {
			target: { value: "wrongpass" },
		});
		fireEvent.change(screen.getByLabelText(/^new password$/i), { target: { value: "newpass12" } });
		fireEvent.change(screen.getByLabelText(/confirm new password/i), {
			target: { value: "newpass12" },
		});
		fireEvent.click(screen.getByRole("button", { name: /change password/i }));

		expect(await screen.findByText(/invalid_password/i)).toBeInTheDocument();
		expect(logout).not.toHaveBeenCalled();
		expect(navigate).not.toHaveBeenCalled();
	});
});
