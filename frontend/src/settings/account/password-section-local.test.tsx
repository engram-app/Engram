import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../../api/client";
import { PasswordSectionLocal } from "./password-section-local";

const { logout, apiPost, navigate } = vi.hoisted(() => ({
	logout: vi.fn().mockResolvedValue(undefined),
	apiPost: vi.fn().mockResolvedValue({ ok: true }),
	navigate: vi.fn(),
}));

vi.mock("../../auth/use-auth-adapter", () => ({
	useAuthAdapter: () => ({ logout }),
}));

vi.mock("../../api/client", async (importOriginal) => ({
	ApiError: (await importOriginal<typeof import("../../api/client")>()).ApiError,
	api: { post: apiPost },
}));

vi.mock("react-router", () => ({ useNavigate: () => navigate }));

beforeEach(() => {
	logout.mockReset().mockResolvedValue(undefined);
	apiPost.mockReset().mockResolvedValue({ ok: true });
	navigate.mockReset();
});

describe("PasswordSectionLocal", () => {
	it("blocks submit when new + confirm mismatch", async () => {
		render(<PasswordSectionLocal />);
		fireEvent.change(screen.getByLabelText(/current password/iu), { target: { value: "old" } });
		fireEvent.change(screen.getByLabelText(/^new password$/iu), { target: { value: "newpass12" } });
		fireEvent.change(screen.getByLabelText(/confirm new password/iu), {
			target: { value: "different" },
		});
		fireEvent.click(screen.getByRole("button", { name: /change password/iu }));

		expect(await screen.findByText(/passwords do not match/iu)).toBeInTheDocument();
		expect(apiPost).not.toHaveBeenCalled();
	});

	it("submits, logs out, and redirects on success", async () => {
		render(<PasswordSectionLocal />);
		fireEvent.change(screen.getByLabelText(/current password/iu), {
			target: { value: "oldpass12" },
		});
		fireEvent.change(screen.getByLabelText(/^new password$/iu), { target: { value: "newpass12" } });
		fireEvent.change(screen.getByLabelText(/confirm new password/iu), {
			target: { value: "newpass12" },
		});
		fireEvent.click(screen.getByRole("button", { name: /change password/iu }));

		await waitFor(() =>
			expect(apiPost).toHaveBeenCalledWith("/auth/password/change", {
				old_password: "oldpass12",
				new_password: "newpass12",
			}),
		);
		await waitFor(() => expect(logout).toHaveBeenCalled());
		await waitFor(() => expect(navigate).toHaveBeenCalledWith("/sign-in"));
	});

	// The server's code maps to a translated sentence; its raw text never shows.
	it("surfaces backend error and does not sign out", async () => {
		apiPost.mockReset().mockRejectedValueOnce(new ApiError(422, "invalid_password"));
		render(<PasswordSectionLocal />);
		fireEvent.change(screen.getByLabelText(/current password/iu), {
			target: { value: "wrongpass" },
		});
		fireEvent.change(screen.getByLabelText(/^new password$/iu), { target: { value: "newpass12" } });
		fireEvent.change(screen.getByLabelText(/confirm new password/iu), {
			target: { value: "newpass12" },
		});
		fireEvent.click(screen.getByRole("button", { name: /change password/iu }));

		expect(await screen.findByText("Incorrect password.")).toBeInTheDocument();
		expect(screen.queryByText(/invalid_password/iu)).toBeNull();
		expect(logout).not.toHaveBeenCalled();
		expect(navigate).not.toHaveBeenCalled();
	});
});
