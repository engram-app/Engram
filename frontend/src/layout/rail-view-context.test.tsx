import { act, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it } from "vitest";
import { RailViewProvider, useRailView } from "./rail-view-context";

function Probe() {
	const { view, setView } = useRailView();
	return (
		<>
			<span data-testid="view">{view}</span>
			<button type="button" onClick={() => setView("search")}>
				to-search
			</button>
			<button type="button" onClick={() => setView("files")}>
				to-files
			</button>
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

function SidebarProbe() {
	const { sidebarOpen, setSidebarOpen } = useRailView();
	return (
		<>
			<span data-testid="open">{String(sidebarOpen)}</span>
			<button type="button" onClick={() => setSidebarOpen(!sidebarOpen)}>
				flip
			</button>
		</>
	);
}

describe("RailViewContext — left sidebar open state", () => {
	beforeEach(() => window.localStorage.clear());

	const renderProbe = () =>
		render(
			<RailViewProvider>
				<SidebarProbe />
			</RailViewProvider>,
		);

	it("starts open", () => {
		renderProbe();
		expect(screen.getByTestId("open").textContent).toBe("true");
	});

	it("persists a collapse and restores it on the next mount", () => {
		const { unmount } = renderProbe();
		act(() => screen.getByText("flip").click());
		expect(screen.getByTestId("open").textContent).toBe("false");
		expect(window.localStorage.getItem("engram:sidebar-open")).toBe("false");
		unmount();
		renderProbe();
		expect(screen.getByTestId("open").textContent).toBe("false");
	});

	it("ignores malformed stored values and stays open", () => {
		window.localStorage.setItem("engram:sidebar-open", "maybe");
		renderProbe();
		expect(screen.getByTestId("open").textContent).toBe("true");
	});
});
