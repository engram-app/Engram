import { render, screen } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { RightToolsProvider, useRightTools } from "../layout/right-tools-context";
import Dashboard from "./dashboard";

const useVaultsSpy = vi.fn(() => ({ data: [{ id: "v1", name: "Vault" }] }));
// Vault-wide note inventory. Two notes by default so the single-note auto-open
// below does not fire in the tests that are about the empty pane.
interface ManifestResult {
	data: { notes: { id: string; path: string }[] } | undefined;
	isPending: boolean;
}
const useSyncManifestSpy = vi.fn(
	(): ManifestResult => ({
		data: {
			notes: [
				{ id: "n-1", path: "A.md" },
				{ id: "n-2", path: "B.md" },
			],
		},
		isPending: false,
	}),
);

vi.mock("../api/queries", () => ({
	useVaults: () => useVaultsSpy(),
	useFolderNotes: () => ({ data: [], isLoading: false, isError: false }),
	useSyncManifest: () => useSyncManifestSpy(),
}));

vi.mock("../api/vault-slug", async () => {
	const actual = await vi.importActual<typeof import("../api/vault-slug")>("../api/vault-slug");
	return { ...actual, useActiveVaultSlug: () => "work" };
});

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

// A brand-new vault holds exactly one note — the seeded welcome note — and
// landing on "No note is open" with it one unexplained click away is the wrong
// first screen. Keyed on the count, not the path: the path is owned by
// `Engram.Vaults.WelcomeNote` in Elixir and a frontend copy would drift.
describe("Dashboard single-note auto-open", () => {
	const twoNotes = {
		data: {
			notes: [
				{ id: "n-1", path: "A.md" },
				{ id: "n-2", path: "B.md" },
			],
		},
		isPending: false,
	};

	beforeEach(() => {
		useSyncManifestSpy.mockReturnValue(twoNotes);
	});

	function LocationProbe() {
		const loc = useLocation();
		return <span data-testid="loc">{loc.pathname}</span>;
	}

	function renderAt(url: string) {
		return render(
			<MemoryRouter initialEntries={[url]}>
				<RightToolsProvider>
					<Dashboard />
					<LocationProbe />
				</RightToolsProvider>
			</MemoryRouter>,
		);
	}

	it("opens the note when the vault holds exactly one", () => {
		useSyncManifestSpy.mockReturnValue({
			data: { notes: [{ id: "welcome-id", path: "Welcome to Engram.md" }] },
			isPending: false,
		});
		renderAt("/");
		expect(screen.getByTestId("loc").textContent).toBe("/v/work/welcome-id");
	});

	it("stays on the empty pane once a second note exists", () => {
		renderAt("/");
		expect(screen.getByLabelText("No note open")).toBeInTheDocument();
	});

	it("stays put for an empty vault", () => {
		useSyncManifestSpy.mockReturnValue({ data: { notes: [] }, isPending: false });
		renderAt("/");
		expect(screen.getByLabelText("No note open")).toBeInTheDocument();
	});

	// A ?folder= browse is a deliberate destination, not a landing.
	it("does not hijack a folder browse", () => {
		useSyncManifestSpy.mockReturnValue({
			data: { notes: [{ id: "welcome-id", path: "Welcome to Engram.md" }] },
			isPending: false,
		});
		renderAt("/?folder=Notes");
		// The folder heading, not the note list: useFolderNotes is mocked empty.
		expect(screen.getByRole("heading", { name: "Notes" })).toBeInTheDocument();
		expect(screen.queryByLabelText("No note open")).not.toBeInTheDocument();
	});

	// Painting the empty pane and yanking it away IS the first impression on a
	// new vault, so the manifest has to land before anything renders.
	it("holds instead of flashing the empty pane while the manifest loads", () => {
		useSyncManifestSpy.mockReturnValue({ data: undefined, isPending: true });
		renderAt("/");
		expect(screen.queryByLabelText("No note open")).not.toBeInTheDocument();
	});
});
