import { render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router";
import { describe, expect, it, vi } from "vitest";
import LegacySettingsRedirect from "./legacy-settings-redirect";
import SettingsOverlayHost from "./settings-overlay-host";

// The dialog pulls the whole settings surface (Clerk hooks, billing, admin);
// stub it so this file tests only the host's mount decision.
vi.mock("./settings-layout", () => ({
	default: ({ section }: { section: string }) => <p data-testid="dialog">section:{section}</p>,
}));

function LocationProbe() {
	const loc = useLocation();
	return <output data-testid="loc">{`${loc.pathname}${loc.search}${loc.hash}`}</output>;
}

function renderHost(entry: string) {
	return render(
		<MemoryRouter initialEntries={[entry]}>
			<Routes>
				<Route element={<SettingsOverlayHost />}>
					<Route path="/v/work/:id" element={<p>note body</p>} />
				</Route>
			</Routes>
		</MemoryRouter>,
	);
}

describe("SettingsOverlayHost", () => {
	it("renders the page alone when there is no settings hash", () => {
		renderHost("/v/work/note-1");
		expect(screen.getByText("note body")).toBeInTheDocument();
		expect(screen.queryByTestId("dialog")).toBeNull();
	});

	it("keeps the page mounted underneath when settings is open", async () => {
		renderHost("/v/work/note-1#settings/billing");
		// The page underneath is synchronous (plain Outlet), but the dialog is
		// lazy(), so it sits behind a Suspense boundary that resolves on a
		// microtask. `vi.mock` does not make the dynamic import synchronous.
		// Await the dialog; asserting it with a sync getBy* would always throw.
		expect(screen.getByText("note body")).toBeInTheDocument();
		expect(await screen.findByTestId("dialog")).toHaveTextContent("section:billing");
	});

	it("ignores unrelated hashes", () => {
		renderHost("/v/work/note-1#tour");
		expect(screen.queryByTestId("dialog")).toBeNull();
	});
});

describe("LegacySettingsRedirect", () => {
	function renderRedirect(entry: string) {
		return render(
			<MemoryRouter initialEntries={[entry]}>
				<LocationProbe />
				<Routes>
					<Route path="/settings" element={<LegacySettingsRedirect />} />
					<Route path="/settings/*" element={<LegacySettingsRedirect />} />
					<Route path="/" element={<p>root</p>} />
				</Routes>
			</MemoryRouter>,
		);
	}

	it("maps a bare /settings to the account hash", () => {
		renderRedirect("/settings");
		expect(screen.getByTestId("loc")).toHaveTextContent("/#settings/account");
	});

	it("maps a section path to its hash", () => {
		renderRedirect("/settings/billing");
		expect(screen.getByTestId("loc")).toHaveTextContent("/#settings/billing");
	});

	it("maps the legacy api-keys path to connections", () => {
		renderRedirect("/settings/api-keys");
		expect(screen.getByTestId("loc")).toHaveTextContent("/#settings/connections");
	});

	it("preserves the query string", () => {
		renderRedirect("/settings/vaults?highlight=abc");
		expect(screen.getByTestId("loc")).toHaveTextContent("/?highlight=abc#settings/vaults");
	});
});
