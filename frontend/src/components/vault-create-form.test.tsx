import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { VaultCreateForm } from "./vault-create-form";

// vi.mock factories run at the top of the file — declare their fakes
// via vi.hoisted so the references resolve when the mock executes.
const { mutate, toastError, toastSuccess } = vi.hoisted(() => ({
	mutate: vi.fn(),
	toastError: vi.fn(),
	toastSuccess: vi.fn(),
}));

vi.mock("@/api/queries", () => ({
	useCreateVault: () => ({ mutate, isPending: false }),
}));

vi.mock("sonner", () => ({ toast: { error: toastError, success: toastSuccess } }));

describe("VaultCreateForm onError", () => {
	beforeEach(() => vi.clearAllMocks());

	function submitWithError(err: Error) {
		mutate.mockImplementation((_attrs, opts) => opts?.onError?.(err));
		render(<VaultCreateForm />);
		fireEvent.change(screen.getByLabelText(/vault name/iu), { target: { value: "A" } });
		fireEvent.click(screen.getByRole("button", { name: /create/iu }));
	}

	it("shows a toast on a generic failure", async () => {
		submitWithError(new Error("boom"));
		await waitFor(() => expect(toastError).toHaveBeenCalledWith("Could not create vault"));
	});

	it("stays silent on LimitExceededError — UpgradeDialog owns that surface", async () => {
		const limitErr = Object.assign(new Error("limit reached"), { name: "LimitExceededError" });
		submitWithError(limitErr);
		// Give the mutation callback a tick — toast must NOT fire.
		await new Promise((r) => setTimeout(r, 10));
		expect(toastError).not.toHaveBeenCalled();
	});
});

describe("VaultCreateForm idempotency key", () => {
	beforeEach(() => vi.clearAllMocks());

	function submit(name: string) {
		fireEvent.change(screen.getByLabelText(/vault name/iu), { target: { value: name } });
		fireEvent.click(screen.getByRole("button", { name: /create/iu }));
	}

	it("reuses one client_id across retries of the same failed create", () => {
		mutate.mockImplementation((_attrs, opts) => opts?.onError?.(new Error("boom")));
		render(<VaultCreateForm />);

		submit("A");
		submit("A");

		// Retrying a create that may already have landed server-side MUST carry
		// the same key, or the retry mints a second vault.
		expect(mutate.mock.calls[0]![0].client_id).toBe(mutate.mock.calls[1]![0].client_id);
	});

	it("mints a fresh client_id after a success, since that is a new intent", () => {
		mutate.mockImplementation((_attrs, opts) =>
			opts?.onSuccess?.({ id: "v1", slug: "a", name: "A" }),
		);
		render(<VaultCreateForm />);

		submit("A");
		submit("B");

		expect(mutate.mock.calls[0]![0].client_id).not.toBe(mutate.mock.calls[1]![0].client_id);
	});

	it("hands onCreated the flat vault that /vaults/register returns", () => {
		const vault = { id: "v1", slug: "archive", name: "Archive" };
		mutate.mockImplementation((_attrs, opts) => opts?.onSuccess?.(vault));
		const onCreated = vi.fn();
		render(<VaultCreateForm onCreated={onCreated} />);

		submit("Archive");

		expect(onCreated).toHaveBeenCalledWith(vault);
	});
});
