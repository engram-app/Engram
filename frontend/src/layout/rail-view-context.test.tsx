import { act, render, screen } from "@testing-library/react";
import { describe, expect, it, beforeEach } from "vitest";
import { RailViewProvider, useRailView } from "./rail-view-context";

function Probe() {
	const { view, setView } = useRailView();
	return (
		<>
			<span data-testid="view">{view}</span>
			<button onClick={() => setView("search")}>to-search</button>
			<button onClick={() => setView("files")}>to-files</button>
		</>
	);
}

describe("RailViewContext", () => {
	beforeEach(() => window.localStorage.clear());

	it("defaults to files", () => {
		render(
			<RailViewProvider>
				<Probe />
			</RailViewProvider>,
		);
		expect(screen.getByTestId("view").textContent).toBe("files");
	});

	it("updates and persists to localStorage", () => {
		render(
			<RailViewProvider>
				<Probe />
			</RailViewProvider>,
		);
		act(() => screen.getByText("to-search").click());
		expect(screen.getByTestId("view").textContent).toBe("search");
		expect(window.localStorage.getItem("engram:rail-view")).toBe("search");
	});

	it("restores from localStorage on mount", () => {
		window.localStorage.setItem("engram:rail-view", "search");
		render(
			<RailViewProvider>
				<Probe />
			</RailViewProvider>,
		);
		expect(screen.getByTestId("view").textContent).toBe("search");
	});

	it("ignores malformed localStorage values", () => {
		window.localStorage.setItem("engram:rail-view", "garbage");
		render(
			<RailViewProvider>
				<Probe />
			</RailViewProvider>,
		);
		expect(screen.getByTestId("view").textContent).toBe("files");
	});
});
