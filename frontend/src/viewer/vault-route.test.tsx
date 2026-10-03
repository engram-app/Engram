import { render, screen, waitFor } from "@testing-library/react";
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

const { toastError } = vi.hoisted(() => ({ toastError: vi.fn() }));
vi.mock("sonner", () => ({ toast: { error: toastError } }));

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
	toastError.mockClear();
});

describe("VaultRoute", () => {
	function renderRoute(entry: string) {
		return render(
			<MemoryRouter initialEntries={[entry]}>
				<LocationProbe />
				<Routes>
					<Route path="/" element={<VaultRedirect />} />
					<Route path="/v/:slug" element={<VaultRoute />}>
						<Route index element={<VaultProbe />} />
						<Route path=":itemId" element={<VaultProbe />} />
					</Route>
				</Routes>
			</MemoryRouter>,
		);
	}

	it("resolves the slug and renders children under that vault", async () => {
		renderRoute("/v/work");
		expect(await screen.findByTestId("child")).toHaveTextContent("id-a");
	});

	it("never renders children under the previous vault", async () => {
		setActiveVaultId("id-b");
		renderRoute("/v/work");
		const child = await screen.findByTestId("child");
		// If VaultRoute rendered its Outlet before the store caught up, this
		// would have been "id-b" for one pass and ~25 queries would have fired
		// against the wrong vault.
		expect(child).toHaveTextContent("id-a");
	});

	// VaultRoute renders inside the app shell, so a full-page 404 here showed
	// up nested in the content pane next to the previous vault's sidebar. An
	// unknown slug is almost always a typo or a renamed vault: say so, and land
	// on the vault `/` would pick, the same way a missing note lands on its
	// vault root.
	it("sends an unknown slug to the preferred vault and says why", async () => {
		setActiveVaultId("id-a");
		renderRoute("/v/nope");
		await waitFor(() => expect(screen.getByTestId("loc")).toHaveTextContent("/v/work"));
		expect(toastError).toHaveBeenCalledTimes(1);
		expect(toastError.mock.calls[0]?.[0]).toMatch(/nope/u);
		expect(screen.queryByText(/not found/i)).toBeNull();
	});

	it("does the same for an item URL under an unknown slug", async () => {
		renderRoute("/v/nope/n-1");
		await waitFor(() => expect(screen.getByTestId("loc")).toHaveTextContent("/v/personal"));
		expect(toastError).toHaveBeenCalledTimes(1);
	});

	it("waits rather than 404ing while the vault list is loading", () => {
		mockVaults = undefined;
		mockPending = true;
		renderRoute("/v/work");
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
					<Route path="/v/:slug" element={<p>vault page</p>} />
				</Routes>
			</MemoryRouter>,
		);
	}

	it("redirects to the hinted vault", async () => {
		setActiveVaultId("id-a");
		renderRedirect("/");
		expect((await screen.findByTestId("loc")).textContent).toBe("/v/work");
	});

	it("redirects to the default vault with no hint", async () => {
		renderRedirect("/");
		expect((await screen.findByTestId("loc")).textContent).toBe("/v/personal");
	});

	it("preserves search and hash across the bounce", async () => {
		renderRedirect("/?highlight=abc#settings/vaults");
		expect((await screen.findByTestId("loc")).textContent).toBe(
			"/v/personal?highlight=abc#settings/vaults",
		);
	});

	it("renders the empty state when there are no vaults", () => {
		mockVaults = [];
		renderRedirect("/");
		expect(screen.getByText(/no vaults/i)).toBeInTheDocument();
	});
});

describe("LegacyNoteRedirect", () => {
	it("renders the empty state, not a 404, when there are no vaults", () => {
		mockVaults = [];
		render(
			<MemoryRouter initialEntries={["/note/n-1"]}>
				<Routes>
					<Route path="/note/:id" element={<LegacyNoteRedirect />} />
				</Routes>
			</MemoryRouter>,
		);
		expect(screen.getByText(/no vaults/i)).toBeInTheDocument();
		expect(screen.queryByText(/not found/i)).toBeNull();
	});

	it("rewrites /note/:id to /v/:slug/:id using the hinted vault", async () => {
		setActiveVaultId("id-a");
		render(
			<MemoryRouter initialEntries={["/note/n-1"]}>
				<LocationProbe />
				<Routes>
					<Route path="/note/:id" element={<LegacyNoteRedirect />} />
					<Route path="/v/:slug/:itemId" element={<p>note page</p>} />
				</Routes>
			</MemoryRouter>,
		);
		expect((await screen.findByTestId("loc")).textContent).toBe("/v/work/n-1");
	});
});
