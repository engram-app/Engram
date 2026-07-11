import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";
import { RightSidebarProvider, useRightSidebar } from "../layout/right-sidebar-context";
import Dashboard from "./dashboard";

const useVaultsSpy = vi.fn(() => ({ data: [{ id: "v1", name: "Vault" }] }));

vi.mock("../api/queries", () => ({
	useVaults: () => useVaultsSpy(),
	useFolderNotes: () => ({ data: [], isLoading: false, isError: false }),
}));

function RightProbe() {
	const { content } = useRightSidebar();
	return <span data-testid="has-right">{content === null ? "no" : "yes"}</span>;
}

function renderDashboard(url = "/") {
	return render(
		<MemoryRouter initialEntries={[url]}>
			<RightSidebarProvider>
				<Dashboard />
				<RightProbe />
			</RightSidebarProvider>
		</MemoryRouter>,
	);
}

describe("Dashboard (no note open)", () => {
	it("renders an empty document pane instead of the welcome card", () => {
		renderDashboard();
		expect(screen.getByLabelText("No note open")).toBeInTheDocument();
		expect(screen.queryByText(/welcome to engram/iu)).not.toBeInTheDocument();
	});

	it("mounts right-sidebar content so the panel shows like an open note", () => {
		renderDashboard();
		expect(screen.getByTestId("has-right").textContent).toBe("yes");
	});

	it("keeps the tour anchor", () => {
		const { container } = renderDashboard();
		expect(container.querySelector('[data-tour="dashboard-root"]')).not.toBeNull();
	});

	it("still shows the create-a-vault empty state when no vaults exist", () => {
		useVaultsSpy.mockReturnValueOnce({ data: [] });
		renderDashboard();
		expect(screen.queryByLabelText("No note open")).not.toBeInTheDocument();
	});
});
