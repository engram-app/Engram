import { act, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
	getActiveVaultId,
	resetActiveVaultToStored,
	setActiveVaultId,
} from "../../api/active-vault";
import { DemoVaultProvider, useDemoVault } from "./demo-vault-provider";

const Probe = () => {
	const ctx = useDemoVault();
	return <div data-testid="probe">{ctx.active ? ctx.vault?.name : "inactive"}</div>;
};

describe("DemoVaultProvider", () => {
	beforeEach(() => {
		localStorage.clear();
		resetActiveVaultToStored();
		globalThis.fetch = vi.fn(() =>
			Promise.resolve({
				ok: true,
				json: () =>
					Promise.resolve({
						vault: { id: "demo-vault", name: "Demo Vault" },
						folders: [],
						notes: [],
					}),
			} as Response),
		) as unknown as typeof fetch;
	});

	it("inactive by default, active after activate()", async () => {
		let activate!: () => Promise<void>;
		function Capture() {
			({ activate } = useDemoVault());
			return null;
		}
		render(
			<DemoVaultProvider>
				<Probe />
				<Capture />
			</DemoVaultProvider>,
		);

		expect(screen.getByTestId("probe").textContent).toBe("inactive");
		await act(async () => {
			await activate();
		});
		expect(screen.getByTestId("probe").textContent).toBe("Demo Vault");
	});

	it("deactivate() drops a demo active-vault selection back to the stored real vault", async () => {
		// A real vault was selected before the tour started.
		setActiveVaultId("42");

		let activate!: () => Promise<void>;
		let deactivate!: () => void;
		function Capture() {
			({ activate, deactivate } = useDemoVault());
			return null;
		}
		render(
			<DemoVaultProvider>
				<Capture />
			</DemoVaultProvider>,
		);

		await act(async () => {
			await activate();
		});
		// The tour gates a step on switching to a fake vault.
		act(() => {
			setActiveVaultId("demo-vault-2");
		});
		expect(getActiveVaultId()).toBe("demo-vault-2");

		// Leaving the tour must restore the real vault, not leave the demo id live.
		act(() => {
			deactivate();
		});
		expect(getActiveVaultId()).toBe("42");
	});
});
