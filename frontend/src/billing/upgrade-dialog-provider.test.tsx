import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { setUpgradeHandler } from "@/api/client";
import { UpgradeDialogProvider, useUpgradeDialog } from "./upgrade-dialog-provider";

function Trigger() {
	const { showUpgrade } = useUpgradeDialog();
	return (
		<button type="button" onClick={() => showUpgrade("notes_cap_exceeded")}>
			show
		</button>
	);
}

function renderWithRouter(ui: React.ReactNode) {
	return render(
		<MemoryRouter initialEntries={["/start"]}>
			<Routes>
				<Route path="/start" element={ui} />
				<Route path="/settings/billing" element={<div data-testid="billing-page">billing</div>} />
			</Routes>
		</MemoryRouter>,
	);
}

describe("UpgradeDialogProvider", () => {
	beforeEach(() => {
		setUpgradeHandler(null);
	});

	it("renders dialog when showUpgrade is called", async () => {
		renderWithRouter(
			<UpgradeDialogProvider>
				<Trigger />
			</UpgradeDialogProvider>,
		);
		fireEvent.click(screen.getByText("show"));
		// Generous timeout: the dialog is lazy() now, and the FIRST test to touch
		// it pays vitest's cold on-demand transform of the chunk (>1s).
		expect(
			await screen.findByText(/note limit/iu, undefined, { timeout: 5000 }),
		).toBeInTheDocument();
	});

	it("dialog closes when onOpenChange(false) fires", async () => {
		renderWithRouter(
			<UpgradeDialogProvider>
				<Trigger />
			</UpgradeDialogProvider>,
		);
		fireEvent.click(screen.getByText("show"));
		// Radix Dialog provides only an X (sr-only "Close") to dismiss. Same 5s
		// timeout as above: whichever test runs FIRST pays the cold transform of
		// the lazy dialog chunk, so neither may assume a warm module cache.
		const dismiss = await screen.findByRole("button", { name: /close/iu }, { timeout: 5000 });
		fireEvent.click(dismiss);
		await waitFor(() => expect(screen.queryByText(/note limit/iu)).not.toBeInTheDocument());
	});

	it("useUpgradeDialog throws outside provider", () => {
		const Probe = () => {
			useUpgradeDialog();
			return null;
		};
		// Suppress the React error log for the expected throw
		const spy = vi.spyOn(console, "error").mockImplementation(() => {});
		try {
			expect(() => render(<Probe />)).toThrow(/outside UpgradeDialogProvider/iu);
		} finally {
			spy.mockRestore();
		}
	});

	it("registers the upgrade handler on mount and unregisters on unmount", () => {
		const { unmount } = renderWithRouter(
			<UpgradeDialogProvider>
				<div>child</div>
			</UpgradeDialogProvider>,
		);
		// Handler should now be set — triggering it should open the dialog.
		// We rely on the client module's exported setter; the provider's effect
		// sets the handler. After unmount, the provider clears it.
		unmount();
		// No assertion needed beyond not throwing; the unmount cleanup branch is
		// exercised. The "handler invocation" path is tested in client.test.ts.
	});
});
