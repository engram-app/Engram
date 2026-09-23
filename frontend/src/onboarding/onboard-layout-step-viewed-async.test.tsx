/**
 * `onboard-layout.test.tsx` mocks `useOnboardingStatus` as synchronously
 * loaded, so it can't observe a bug where the step-viewed effect fires while
 * the query is still loading, then never re-fires once it resolves (the
 * dependency array is keyed on `current` alone, and `current` doesn't change
 * across that transition). That is exactly the cold-load case the event
 * exists to catch — the `/onboard` route sits outside `OnboardingGate`'s
 * bootstrap seed, so a real first visit hits this query uncached.
 *
 * Its own file, following `sentry-init-wiring.test.ts`'s precedent: it needs
 * the REAL `useOnboardingStatus` (real `useQuery`, real loading state), which
 * `onboard-layout.test.tsx` mocks away for every other test in that file.
 */
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import { track } from "../analytics/track";
import type { OnboardingStatus } from "../api/queries";
import OnboardLayout from "./onboard-layout";

vi.mock("../analytics/track", () => ({ track: vi.fn() }));
const mockTrack = vi.mocked(track);

vi.mock("../auth/use-auth-adapter", () => ({
	useAuthAdapter: () => ({ logout: vi.fn() }),
}));

vi.mock("../theme/theme-toggle", () => ({
	default: () => null,
}));

// Only `api.get` is faked — everything else in `api/client` (ApiError, etc.)
// stays real in case anything downstream touches it.
const { get } = vi.hoisted(() => ({ get: vi.fn() }));
vi.mock("../api/client", async (importOriginal) => {
	const actual = await importOriginal<typeof import("../api/client")>();
	return { ...actual, api: { ...actual.api, get } };
});

afterEach(() => {
	mockTrack.mockClear();
	get.mockReset();
});

function renderAt(path: string) {
	const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return render(
		<QueryClientProvider client={qc}>
			<MemoryRouter initialEntries={[path]}>
				<Routes>
					<Route element={<OnboardLayout />}>
						<Route path="/onboard/agreement" element={<p>agreement step</p>} />
					</Route>
				</Routes>
			</MemoryRouter>
		</QueryClientProvider>,
	);
}

describe("OnboardLayout — onboarding_step_viewed on a cold load (real react-query)", () => {
	it("fires once the status query resolves, even though the first render was still loading", async () => {
		let resolveStatus!: (value: OnboardingStatus) => void;
		get.mockImplementation(
			() =>
				new Promise((resolve) => {
					resolveStatus = resolve;
				}),
		);

		renderAt("/onboard/agreement");

		// Still loading on mount — the effect's guard bails here. This is the
		// render the bug hides in: `current` is already "agreement" and never
		// changes again, so a dependency array keyed on `current` alone gets no
		// second chance once the query resolves.
		expect(mockTrack).not.toHaveBeenCalled();

		resolveStatus({
			enabled: true,
			next_step: "agreement",
			gate_ok: false,
			steps: ["agreement", "billing", "tools", "vault"],
			actions: [],
			vault_count: 0,
		} as OnboardingStatus);

		await waitFor(() =>
			expect(mockTrack).toHaveBeenCalledWith("onboarding_step_viewed", { step: "agreement" }),
		);
		expect(mockTrack).toHaveBeenCalledTimes(1);
	});
});
