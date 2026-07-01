import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { CreateFirstVaultModal } from "./create-first-vault-modal";

const DEMO_VAULT_ID = "01923a4b-cdef-7000-89ab-cdef01234567";

vi.mock("../components/vault-create-form", () => ({
	VaultCreateForm: ({ onCreated }: { onCreated: (id: string) => void }) => (
		<button onClick={() => onCreated(DEMO_VAULT_ID)}>fake-create</button>
	),
}));

describe("CreateFirstVaultModal", () => {
	it("renders heading; ESC does nothing; onCreated bubbles", () => {
		const onCreated = vi.fn();
		render(<CreateFirstVaultModal onCreated={onCreated} />);

		expect(screen.getByRole("heading", { name: /first vault/i })).toBeInTheDocument();

		fireEvent.keyDown(document, { key: "Escape" });
		expect(screen.getByRole("heading", { name: /first vault/i })).toBeInTheDocument();

		fireEvent.click(screen.getByText("fake-create"));
		expect(onCreated).toHaveBeenCalledWith(DEMO_VAULT_ID);
	});
});
