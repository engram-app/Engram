import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { useEffect } from "react";
import { MemoryRouter, Navigate, Route, Routes, useLocation } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";

const { get, post } = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn() }));
vi.mock("../api/client", () => ({
	api: { get, post, patch: vi.fn(), del: vi.fn() },
	setTokenGetter: vi.fn(),
}));

// Stub the legal doc loaders so this test doesn't depend on which version
// strings are bundled in the build.
vi.mock("../legal/load", () => ({
	loadVersion: () => "# Terms\n\nMock terms content.",
	sha256Hex: async () => "a".repeat(64),
}));

import { useOnboardingStatus } from "../api/queries";
import AgreementPage from "./agreement-page";

function LocationProbe() {
	const loc = useLocation();
	return <div data-testid="path">{loc.pathname}</div>;
}

// Mimic the real OnboardRedirect — reads cached status and immediately navigates
// to the indicated next step. The whole race lives in step 4 of submit-then-navigate:
// `OnboardRedirect` runs while the post-mutation refetch is still in flight,
// and routes the user wherever the *current cache value* says.
function OnboardRedirect() {
	const { data, isLoading } = useOnboardingStatus();
	if (isLoading || !data) {
		return null;
	}
	return <Navigate to={`/onboard/${data.next_step}`} replace />;
}

let agreementMounts = 0;
function CountingAgreementPage() {
	useEffect(() => {
		agreementMounts++;
	}, []);
	return <AgreementPage />;
}

const STATUS_BEFORE = {
	enabled: true,
	next_step: "agreement",
	current_tos_version: "v2.0",
	current_privacy_version: "v1.0",
	terms_ok: false,
	subscription_ok: false,
};
const STATUS_AFTER = {
	...STATUS_BEFORE,
	next_step: "billing",
	terms_ok: true,
};

describe("AgreementPage accept-then-redirect flow", () => {
	beforeEach(() => {
		get.mockReset();
		post.mockReset();
		agreementMounts = 0;
	});

	it("lands on /onboard/billing after one accept (no double-accept loop)", async () => {
		let accepted = false;
		let statusGetCalls = 0;
		get.mockImplementation(async (url: string) => {
			if (url !== "/onboarding/status") {
				throw new Error(`unexpected GET ${url}`);
			}
			statusGetCalls++;
			// The initial mount fetch returns instantly so the page renders. The
			// refetch that invalidation triggers takes 80ms — long enough that
			// OnboardRedirect would observably read a stale cache if onSuccess
			// didn't await invalidation.
			if (statusGetCalls > 1) {
				await new Promise((r) => setTimeout(r, 80));
			}
			return accepted ? STATUS_AFTER : STATUS_BEFORE;
		});
		post.mockImplementation(async (url: string) => {
			if (url !== "/onboarding/accept-terms") {
				throw new Error(`unexpected POST ${url}`);
			}
			await new Promise((r) => setTimeout(r, 20));
			accepted = true;
			return { version: "v2.0", accepted_at: "now" };
		});

		const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
		render(
			<QueryClientProvider client={qc}>
				<MemoryRouter initialEntries={["/onboard/agreement"]}>
					<LocationProbe />
					<Routes>
						<Route path="/onboard/agreement" element={<CountingAgreementPage />} />
						<Route path="/onboard" element={<OnboardRedirect />} />
						<Route path="/onboard/billing" element={<div data-testid="billing-landed" />} />
					</Routes>
				</MemoryRouter>
			</QueryClientProvider>,
		);

		fireEvent.click(await screen.findByRole("checkbox", { name: /agree/iu }));
		fireEvent.click(screen.getByRole("button", { name: /continue/iu }));

		// With the fix, the mutation only resolves after the cache is refreshed,
		// so OnboardRedirect reads STATUS_AFTER and routes to /onboard/billing.
		// Without the fix, OnboardRedirect reads STATUS_BEFORE (stale) and routes
		// back to /onboard/agreement, re-mounting CountingAgreementPage.
		await waitFor(() => expect(screen.getByTestId("billing-landed")).toBeInTheDocument());

		expect(screen.getByTestId("path").textContent).toBe("/onboard/billing");
		expect(agreementMounts).toBe(1);
		expect(post).toHaveBeenCalledTimes(1);
	});
});
