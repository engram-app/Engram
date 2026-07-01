import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";
import { describe, expect, it } from "vitest";
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
		expect(screen.getByText(/pro feature/iu)).toBeInTheDocument();
	});

	it("Upgrade button navigates to /settings/billing", async () => {
		renderWithRouter(
			<UpgradeRequiredDialog reason="notes_cap_exceeded" open={true} onOpenChange={() => {}} />,
		);
		fireEvent.click(screen.getByRole("button", { name: /upgrade/iu }));
		expect(await screen.findByTestId("billing-page")).toBeInTheDocument();
	});

	it("has no explicit Dismiss button — X / outside click / Escape still close", () => {
		renderWithRouter(
			<UpgradeRequiredDialog reason="notes_cap_exceeded" open={true} onOpenChange={() => {}} />,
		);
		expect(screen.queryByRole("button", { name: /dismiss/iu })).not.toBeInTheDocument();
	});
});
