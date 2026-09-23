import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { track } from "../analytics/track";
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

function renderPage() {
	return render(
		<MemoryRouter>
			<OnboardVaultPage />
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
