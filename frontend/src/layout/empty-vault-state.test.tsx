import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { describe, expect, it } from "vitest";
import { EmptyVaultState } from "./empty-vault-state";

describe("EmptyVaultState", () => {
	it("prompts the user to create a vault and links to settings", () => {
		render(
			<MemoryRouter>
				<EmptyVaultState />
			</MemoryRouter>,
		);
		expect(screen.getByText(/no vaults/iu)).toBeInTheDocument();
		const link = screen.getByRole("link", { name: /create a vault/iu });
		expect(link).toHaveAttribute("href", "/settings/vaults");
	});
});
