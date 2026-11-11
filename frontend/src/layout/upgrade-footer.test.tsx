import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import { track } from "../analytics/track";
import type { CurrentPlan } from "../billing/use-plan";
import UpgradeFooter from "./upgrade-footer";

const state = vi.hoisted(() => ({
	plan: null as CurrentPlan | null,
	checklistActive: false,
}));
vi.mock("../billing/use-plan", () => ({ usePlan: () => state.plan }));
vi.mock("../onboarding/checklist-widget", () => ({
	useChecklistActive: () => state.checklistActive,
}));
vi.mock("../analytics/track", () => ({ track: vi.fn() }));

function LocationProbe() {
	const { hash } = useLocation();
	return <p data-testid="hash">{hash}</p>;
}

function renderFooter() {
	return render(
		<MemoryRouter>
			<UpgradeFooter />
			<LocationProbe />
		</MemoryRouter>,
	);
}

const FREE = { name: "Free", tier: "free" } as unknown as CurrentPlan;

describe("UpgradeFooter", () => {
	afterEach(() => {
		state.plan = null;
		state.checklistActive = false;
		vi.mocked(track).mockClear();
	});

	it("offers Upgrade to a Free user and opens billing as a sidebar_footer click", () => {
		state.plan = FREE;
		renderFooter();
		fireEvent.click(screen.getByRole("button", { name: "Upgrade" }));
		expect(vi.mocked(track)).toHaveBeenCalledWith("upgrade_link_clicked", {
			source: "sidebar_footer",
		});
		expect(screen.getByTestId("hash")).toHaveTextContent("billing");
	});

	it("waits while the setup checklist, with its own paid-plans line, is still up", () => {
		state.plan = FREE;
		state.checklistActive = true;
		renderFooter();
		expect(screen.queryByRole("button", { name: "Upgrade" })).toBeNull();
	});

	it.each([
		["Starter", { name: "Starter", tier: "starter" }],
		["Pro", { name: "Pro", tier: "pro" }],
	])("is Free-only: nothing on %s", (_label, plan) => {
		state.plan = plan as unknown as CurrentPlan;
		renderFooter();
		expect(screen.queryByRole("button", { name: "Upgrade" })).toBeNull();
	});

	it("shows nothing without a plan (self-host, or status not loaded)", () => {
		renderFooter();
		expect(screen.queryByRole("button", { name: "Upgrade" })).toBeNull();
	});
});
