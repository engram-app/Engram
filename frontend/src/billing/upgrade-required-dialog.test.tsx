import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router";
import { describe, expect, it, vi } from "vitest";
import { track } from "../analytics/track";
import { UpgradeRequiredDialog } from "./upgrade-required-dialog";
import { upgradeSource } from "./upgrade-source";

vi.mock("../analytics/track", () => ({ track: vi.fn() }));

function LocationProbe() {
	const loc = useLocation();
	return <output data-testid="loc">{`${loc.pathname}${loc.hash}`}</output>;
}

function renderWithRouter(ui: React.ReactNode) {
	return render(
		<MemoryRouter initialEntries={["/start"]}>
			<LocationProbe />
			{ui}
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

	it("Upgrade button navigates to the settings billing hash", () => {
		renderWithRouter(
			<UpgradeRequiredDialog reason="notes_cap_exceeded" open={true} onOpenChange={() => {}} />,
		);
		fireEvent.click(screen.getByRole("button", { name: /upgrade/iu }));
		expect(screen.getByTestId("loc")).toHaveTextContent("/start#settings/billing");
	});

	it("Upgrade records the paywall as the upgrade source", () => {
		renderWithRouter(
			<UpgradeRequiredDialog reason="notes_cap_exceeded" open={true} onOpenChange={() => {}} />,
		);
		fireEvent.click(screen.getByRole("button", { name: /upgrade/iu }));
		expect(vi.mocked(track)).toHaveBeenCalledWith("upgrade_link_clicked", { source: "paywall" });
		expect(upgradeSource()).toBe("paywall");
	});

	it("has no explicit Dismiss button — X / outside click / Escape still close", () => {
		renderWithRouter(
			<UpgradeRequiredDialog reason="notes_cap_exceeded" open={true} onOpenChange={() => {}} />,
		);
		expect(screen.queryByRole("button", { name: /dismiss/iu })).not.toBeInTheDocument();
	});
});
