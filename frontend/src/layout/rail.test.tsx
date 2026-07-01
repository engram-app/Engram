import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router";
import { describe, expect, it, vi } from "vitest";
import Rail from "./rail";
import { RailViewProvider, useRailView } from "./rail-view-context";
import { ThemeProvider } from "../theme/theme-provider";

vi.mock("../auth/use-auth-adapter", () => ({
	useAuthAdapter: () => ({ user: { email: "todd@example.com" }, logout: vi.fn() }),
}));

function Wrap({
	children,
	initialEntries,
}: {
	children: React.ReactNode;
	initialEntries?: string[];
}) {
	return (
		<ThemeProvider>
			<MemoryRouter initialEntries={initialEntries ?? ["/"]}>
				<RailViewProvider>{children}</RailViewProvider>
			</MemoryRouter>
		</ThemeProvider>
	);
}

function ActiveProbe() {
	const { view } = useRailView();
	return <span data-testid="view">{view}</span>;
}

function PathProbe() {
	const { pathname } = useLocation();
	return <span data-testid="pathname">{pathname}</span>;
}

describe("Rail", () => {
	it("renders brand, Files, Search, Settings, Account", () => {
		render(
			<Wrap>
				<Rail />
			</Wrap>,
		);
		expect(screen.getByRole("link", { name: /home/i })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "Files" })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "Search" })).toBeInTheDocument();
		expect(screen.getByRole("link", { name: "Settings" })).toHaveAttribute("href", "/settings");
		expect(screen.getByRole("button", { name: "User menu" })).toBeInTheDocument();
	});

	it("clicking Files / Search swaps the active view", () => {
		render(
			<Wrap>
				<Rail />
				<ActiveProbe />
			</Wrap>,
		);
		expect(screen.getByTestId("view").textContent).toBe("files");
		fireEvent.click(screen.getByRole("button", { name: "Search" }));
		expect(screen.getByTestId("view").textContent).toBe("search");
		fireEvent.click(screen.getByRole("button", { name: "Files" }));
		expect(screen.getByTestId("view").textContent).toBe("files");
	});

	it("marks the active view icon with aria-current=page", () => {
		render(
			<Wrap>
				<Rail />
			</Wrap>,
		);
		expect(screen.getByRole("button", { name: "Files" })).toHaveAttribute("aria-current", "page");
		fireEvent.click(screen.getByRole("button", { name: "Search" }));
		expect(screen.getByRole("button", { name: "Search" })).toHaveAttribute("aria-current", "page");
		expect(screen.getByRole("button", { name: "Files" })).not.toHaveAttribute("aria-current");
	});

	it('exposes data-tour="search" on the Search icon', () => {
		render(
			<Wrap>
				<Rail />
			</Wrap>,
		);
		expect(screen.getByRole("button", { name: "Search" })).toHaveAttribute("data-tour", "search");
	});

	it("clicking Files from /settings navigates back to /", () => {
		render(
			<Wrap initialEntries={["/settings"]}>
				<Rail />
				<PathProbe />
			</Wrap>,
		);
		expect(screen.getByTestId("pathname").textContent).toBe("/settings");
		fireEvent.click(screen.getByRole("button", { name: "Files" }));
		expect(screen.getByTestId("pathname").textContent).toBe("/");
	});

	it("clicking Search from /settings navigates back to / and sets view to search", () => {
		render(
			<Wrap initialEntries={["/settings"]}>
				<Rail />
				<PathProbe />
				<ActiveProbe />
			</Wrap>,
		);
		fireEvent.click(screen.getByRole("button", { name: "Search" }));
		expect(screen.getByTestId("pathname").textContent).toBe("/");
		expect(screen.getByTestId("view").textContent).toBe("search");
	});

	it("clicking Files from / does NOT change the pathname", () => {
		render(
			<Wrap initialEntries={["/"]}>
				<Rail />
				<PathProbe />
			</Wrap>,
		);
		fireEvent.click(screen.getByRole("button", { name: "Files" }));
		expect(screen.getByTestId("pathname").textContent).toBe("/");
	});
});
