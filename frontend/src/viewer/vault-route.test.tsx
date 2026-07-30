import { render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { getActiveVaultId, setActiveVaultId } from "../api/active-vault";
import LegacyNoteRedirect from "./legacy-note-redirect";
import VaultRedirect from "./vault-redirect";
import VaultRoute from "./vault-route";

const vaults = [
	{ id: "id-a", slug: "work", is_default: false, name: "Work" },
	{ id: "id-b", slug: "personal", is_default: true, name: "Personal" },
];

let mockVaults: unknown[] | undefined = vaults;
let mockPending = false;

vi.mock("../api/queries", () => ({
	useVaults: () => ({ data: mockVaults, isPending: mockPending }),
}));

// NotFoundPage (rendered on the 404 path) pulls in ThemeToggle, which needs a
// ThemeProvider we are not wiring up here. Same mock as src/not-found.test.tsx.
vi.mock("../theme/theme-toggle", () => ({
	default: () => <button type="button">theme</button>,
}));

function LocationProbe() {
	const loc = useLocation();
	return <output data-testid="loc">{`${loc.pathname}${loc.search}${loc.hash}`}</output>;
}

// Records the active vault id at RENDER time, not in an effect, so the test can
// prove no child ever renders under the wrong vault.
function VaultProbe() {
	return <output data-testid="child">{String(getActiveVaultId())}</output>;
}

beforeEach(() => {
	mockVaults = vaults;
	mockPending = false;
	setActiveVaultId(null);
});

describe("VaultRoute", () => {
	function renderRoute(entry: string) {
		return render(
			<MemoryRouter initialEntries={[entry]}>
				<Routes>
					<Route path="/:slug" element={<VaultRoute />}>
						<Route index element={<VaultProbe />} />
					</Route>
				</Routes>
			</MemoryRouter>,
		);
	}

	it("resolves the slug and renders children under that vault", async () => {
		renderRoute("/work");
		expect(await screen.findByTestId("child")).toHaveTextContent("id-a");
	});

	it("never renders children under the previous vault", async () => {
		setActiveVaultId("id-b");
		renderRoute("/work");
		const child = await screen.findByTestId("child");
		// If VaultRoute rendered its Outlet before the store caught up, this
		// would have been "id-b" for one pass and ~25 queries would have fired
		// against the wrong vault.
		expect(child).toHaveTextContent("id-a");
	});

	it("404s on an unknown slug", () => {
		renderRoute("/nope");
		expect(screen.queryByTestId("child")).toBeNull();
		expect(screen.getByText(/not found/i)).toBeInTheDocument();
	});

	it("waits rather than 404ing while the vault list is loading", () => {
		mockVaults = undefined;
		mockPending = true;
		renderRoute("/work");
		expect(screen.queryByText(/not found/i)).toBeNull();
		expect(screen.queryByTestId("child")).toBeNull();
	});
});

describe("VaultRedirect", () => {
	function renderRedirect(entry: string) {
		return render(
			<MemoryRouter initialEntries={[entry]}>
				<LocationProbe />
				<Routes>
					<Route path="/" element={<VaultRedirect />} />
					<Route path="/:slug" element={<p>vault page</p>} />
				</Routes>
			</MemoryRouter>,
		);
	}

	it("redirects to the hinted vault", async () => {
		setActiveVaultId("id-a");
		renderRedirect("/");
		expect(await screen.findByTestId("loc")).toHaveTextContent("/work");
	});

	it("redirects to the default vault with no hint", async () => {
		renderRedirect("/");
		expect(await screen.findByTestId("loc")).toHaveTextContent("/personal");
	});

	it("preserves search and hash across the bounce", async () => {
		renderRedirect("/?highlight=abc#settings/vaults");
		expect(await screen.findByTestId("loc")).toHaveTextContent(
			"/personal?highlight=abc#settings/vaults",
		);
	});

	it("renders the empty state when there are no vaults", () => {
		mockVaults = [];
		renderRedirect("/");
		expect(screen.getByText(/no vaults/i)).toBeInTheDocument();
	});
});

describe("LegacyNoteRedirect", () => {
	it("rewrites /note/:id to /:slug/:id using the hinted vault", async () => {
		setActiveVaultId("id-a");
		render(
			<MemoryRouter initialEntries={["/note/n-1"]}>
				<LocationProbe />
				<Routes>
					<Route path="/note/:id" element={<LegacyNoteRedirect />} />
					<Route path="/:slug/:itemId" element={<p>note page</p>} />
				</Routes>
			</MemoryRouter>,
		);
		expect(await screen.findByTestId("loc")).toHaveTextContent("/work/n-1");
	});
});
