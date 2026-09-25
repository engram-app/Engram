import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { track } from "../analytics/track";
import { stashPendingDeviceLink } from "../oauth/pending-authorization";
import OnboardVaultPage from "./onboard-vault-page";

vi.mock("../analytics/track", () => ({ track: vi.fn() }));
const mockTrack = vi.mocked(track);

const createVaultMutateAsync = vi.fn().mockResolvedValue({ id: "vault-uuid-1", name: "My Vault" });
const setProfileMutateAsync = vi.fn().mockResolvedValue({});

vi.mock("../api/queries", () => ({
	useOnboardingStatus: () => ({
		data: { next_step: "vault", profile_complete: false, profile: {} },
		isLoading: false,
	}),
	useMe: () => ({ data: { id: "user-1" } }),
	useSetOnboardingProfile: () => ({
		mutateAsync: setProfileMutateAsync,
		isPending: false,
		isError: false,
	}),
	useCreateVault: () => ({ mutateAsync: createVaultMutateAsync, isPending: false }),
}));

vi.mock("../config-context", () => ({
	useConfig: () => ({ authProvider: "cloud" }),
}));

vi.mock("./use-vault-ready-events", () => ({
	useVaultReadyEvents: () => ({ vaultCreated: false, vaultPopulated: false, vaultId: null }),
}));

function LocationProbe() {
	const { pathname, search } = useLocation();
	return <span data-testid="location">{`${pathname}${search}`}</span>;
}

function renderPage() {
	return render(
		<MemoryRouter initialEntries={["/onboard/vault"]}>
			<Routes>
				<Route path="/onboard/vault" element={<OnboardVaultPage />} />
				<Route path="*" element={null} />
			</Routes>
			<LocationProbe />
		</MemoryRouter>,
	);
}

describe("OnboardVaultPage: step-completion tracking", () => {
	beforeEach(() => {
		mockTrack.mockClear();
		createVaultMutateAsync.mockClear();
		setProfileMutateAsync.mockClear();
	});

	it("emits onboarding_step_completed with the new vault_id on the fresh-start path", async () => {
		renderPage();

		fireEvent.click(screen.getByText(/starting fresh/iu));
		fireEvent.click(screen.getByRole("button", { name: /create vault & continue/iu }));

		await waitFor(() =>
			expect(mockTrack).toHaveBeenCalledWith(
				"onboarding_step_completed",
				expect.objectContaining({ step: "vault", vault_id: "vault-uuid-1" }),
			),
		);
	});
});

// Plugin-first signup, parked on /link with its device code. "I already use
// Obsidian" normally waits for the plugin's first sync, but that plugin cannot
// sync until its code is authorized back on /link: waiting here is a deadlock.
describe("OnboardVaultPage: with a device link parked", () => {
	beforeEach(() => {
		window.sessionStorage.clear();
		setProfileMutateAsync.mockClear();
	});

	it("returns to /link with the code once Obsidian is picked", async () => {
		stashPendingDeviceLink("ENGR-7X4K");
		renderPage();

		fireEvent.click(screen.getByText(/i already use obsidian/iu));

		await waitFor(() =>
			expect(screen.getByTestId("location")).toHaveTextContent("/link?code=ENGR-7X4K"),
		);
		expect(setProfileMutateAsync).toHaveBeenCalledWith({ uses_obsidian: true });
	});

	it("waits for the first sync as before when nothing is parked", async () => {
		renderPage();

		fireEvent.click(screen.getByText(/i already use obsidian/iu));

		await waitFor(() => expect(setProfileMutateAsync).toHaveBeenCalled());
		expect(screen.getByTestId("location")).toHaveTextContent("/onboard/vault");
	});
});
