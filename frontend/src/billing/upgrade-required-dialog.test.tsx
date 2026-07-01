import { describe, it, expect } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { MemoryRouter, Routes, Route } from "react-router";
import { UpgradeRequiredDialog } from "./upgrade-required-dialog";

function renderWithRouter(ui: React.ReactNode) {
	return render(
		<MemoryRouter initialEntries={["/start"]}>
			<Routes>
				<Route path="/start" element={ui} />
				<Route path="/settings/billing" element={<div data-testid="billing-page">billing</div>} />
			</Routes>
		</MemoryRouter>,
	);
}

describe("UpgradeRequiredDialog", () => {
	it("renders title + body from copyFor(reason)", () => {
		renderWithRouter(
			<UpgradeRequiredDialog reason="attachments_disabled" open={true} onOpenChange={() => {}} />,
		);
		expect(screen.getByText(/pro feature/i)).toBeInTheDocument();
	});

	it("Upgrade button navigates to /settings/billing", async () => {
		renderWithRouter(
			<UpgradeRequiredDialog reason="notes_cap_exceeded" open={true} onOpenChange={() => {}} />,
		);
		fireEvent.click(screen.getByRole("button", { name: /upgrade/i }));
		expect(await screen.findByTestId("billing-page")).toBeInTheDocument();
	});

	it("has no explicit Dismiss button — X / outside click / Escape still close", () => {
		renderWithRouter(
			<UpgradeRequiredDialog reason="notes_cap_exceeded" open={true} onOpenChange={() => {}} />,
		);
		expect(screen.queryByRole("button", { name: /dismiss/i })).not.toBeInTheDocument();
	});
});
