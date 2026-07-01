import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen, act } from "@testing-library/react";
import { DemoVaultProvider, useDemoVault } from "./demo-vault-provider";

const Probe = () => {
	const ctx = useDemoVault();
	return <div data-testid="probe">{ctx.active ? ctx.vault?.name : "inactive"}</div>;
};

describe("DemoVaultProvider", () => {
	beforeEach(() => {
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
			const ctx = useDemoVault();
			activate = ctx.activate;
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
});
