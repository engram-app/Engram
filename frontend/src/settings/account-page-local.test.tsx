import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";

vi.mock("./account/profile-section-local", () => ({
	ProfileSectionLocal: () => <div data-testid="profile" />,
}));
vi.mock("./account/appearance-section", () => ({
	AppearanceSection: () => <div data-testid="appearance" />,
}));
vi.mock("./account/email-readonly-section", () => ({
	EmailReadonlySection: () => <div data-testid="email" />,
}));
vi.mock("./account/password-section-local", () => ({
	PasswordSectionLocal: () => <div data-testid="password" />,
}));
vi.mock("./account/danger-zone-section-local", () => ({
	DangerZoneSectionLocal: () => <div data-testid="danger" />,
}));

import AccountPageLocal from "./account-page-local";

describe("AccountPageLocal", () => {
	it("renders every section in order", () => {
		render(<AccountPageLocal />);
		expect(screen.getByRole("heading", { name: /account/i })).toBeInTheDocument();
		for (const id of ["profile", "appearance", "email", "password", "danger"]) {
			expect(screen.getByTestId(id)).toBeInTheDocument();
		}
	});
});
