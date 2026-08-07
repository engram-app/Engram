import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";
import { RightToolsProvider, useRightTools } from "../layout/right-tools-context";
import Dashboard from "./dashboard";

const useVaultsSpy = vi.fn(() => ({ data: [{ id: "v1", name: "Vault" }] }));

vi.mock("../api/queries", () => ({
	useVaults: () => useVaultsSpy(),
	useFolderNotes: () => ({ data: [], isLoading: false, isError: false }),
}));

function RightProbe() {
	// The dashboard publishes an (empty) outline so the right panel keeps its
	// chrome when no note is open — same behaviour as before the tool registry.
	const { isAvailable } = useRightTools();
	return <span data-testid="has-right">{isAvailable("outline") ? "yes" : "no"}</span>;
}

function renderDashboard(url = "/") {
	return render(
		<MemoryRouter initialEntries={[url]}>
			<RightToolsProvider>
				<Dashboard />
				<RightProbe />
			</RightToolsProvider>
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

	it("still shows the create-a-vault empty state when no vaults exist", () => {
		useVaultsSpy.mockReturnValueOnce({ data: [] });
		renderDashboard();
		expect(screen.queryByLabelText("No note open")).not.toBeInTheDocument();
	});
});
