import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import { track } from "../analytics/track";
import { useOnboardingStatus } from "../api/queries";
import { stashPendingAuthorization } from "../oauth/pending-authorization";
import OnboardLayout from "./onboard-layout";

const logout = vi.fn();

vi.mock("../auth/use-auth-adapter", () => ({
	useAuthAdapter: () => ({ logout }),
}));

vi.mock("../theme/theme-toggle", () => ({
	default: () => null,
}));

vi.mock("../api/queries", () => ({
	useOnboardingStatus: vi.fn(),
}));

vi.mock("../analytics/track", () => ({ track: vi.fn() }));
const mockTrack = vi.mocked(track);

type Steps = ("agreement" | "billing" | "heard" | "vault")[];

function renderAt(path: string, steps: Steps) {
	vi.mocked(useOnboardingStatus).mockReturnValue({
		data: { enabled: true, next_step: "heard", steps },
		isLoading: false,
		isError: false,
	} as never);

	return render(
		<MemoryRouter initialEntries={[path]}>
			<Routes>
				<Route element={<OnboardLayout />}>
					<Route path="/onboard/agreement" element={<p>agreement step</p>} />
					<Route path="/onboard/billing" element={<p>billing step</p>} />
					<Route path="/onboard/heard" element={<p>heard step</p>} />
					<Route path="/onboard/vault" element={<p>vault step</p>} />
				</Route>
				<Route path="/onboard" element={<p>resolver landing</p>} />
			</Routes>
		</MemoryRouter>,
	);
}

const SAAS: Steps = ["agreement", "billing", "heard", "vault"];
const SELF: Steps = ["vault"];

// Interrupting an OAuth flow for signup is fine, but it has to stay legible:
// the user should know whose authorization is waiting, and be able to refuse
// in a way the client actually hears (access_denied), rather than closing a
// tab the client waits on forever.
// Mid-OAuth signup shows no "Connecting {app}" bar: it cluttered the wizard,
// and the consent screen at the end names the app anyway.
describe("OnboardLayout pending authorization", () => {
	afterEach(() => {
		window.sessionStorage.clear();
	});

	it("shows no connecting bar while an authorization is parked", () => {
		stashPendingAuthorization("?redirect_uri=https://app/cb&state=xyz");

		renderAt("/onboard/heard", SAAS);

		expect(screen.queryByText(/connecting/iu)).toBeNull();
		expect(screen.queryByRole("button", { name: /cancel connection/iu })).toBeNull();
	});
});

describe("OnboardLayout", () => {
	it("renders loading screen while status is pending", () => {
		vi.mocked(useOnboardingStatus).mockReturnValue({
			data: undefined,
			isLoading: true,
			isError: false,
		} as never);
		render(
			<MemoryRouter initialEntries={["/onboard/heard"]}>
				<Routes>
					<Route element={<OnboardLayout />}>
						<Route path="/onboard/heard" element={<p>heard step</p>} />
					</Route>
				</Routes>
			</MemoryRouter>,
		);
		expect(screen.getByText(/loading/iu)).toBeInTheDocument();
	});

	it("numbers hosted agreement step 1 of 4", () => {
		renderAt("/onboard/agreement", SAAS);
		expect(screen.getByText(/step 1 of 4/iu)).toBeInTheDocument();
	});

	it("shows step 2 of 4 on billing (hosted)", () => {
		renderAt("/onboard/billing", SAAS);
		expect(screen.getByText(/step 2 of 4/iu)).toBeInTheDocument();
		expect(screen.getByText("billing step")).toBeInTheDocument();
	});

	it("shows step 3 of 4 on heard (hosted)", () => {
		renderAt("/onboard/heard", SAAS);
		expect(screen.getByText(/step 3 of 4/iu)).toBeInTheDocument();
	});

	it("shows step 4 of 4 on vault (hosted)", () => {
		renderAt("/onboard/vault", SAAS);
		expect(screen.getByText(/step 4 of 4/iu)).toBeInTheDocument();
	});

	it("shows step 1 of 1 on vault (self-host)", () => {
		renderAt("/onboard/vault", SELF);
		expect(screen.getByText(/step 1 of 1/iu)).toBeInTheDocument();
	});

	it("redirects /onboard/heard to /onboard when self-host chain skips it", () => {
		renderAt("/onboard/heard", SELF);
		expect(screen.getByText("resolver landing")).toBeInTheDocument();
	});

	it("redirects /onboard/agreement to /onboard when self-host chain skips it", () => {
		renderAt("/onboard/agreement", SELF);
		expect(screen.getByText("resolver landing")).toBeInTheDocument();
	});

	it("redirects /onboard/billing to /onboard when self-host chain skips it", () => {
		renderAt("/onboard/billing", SELF);
		expect(screen.getByText("resolver landing")).toBeInTheDocument();
	});

	it("signs the user out mid-flow", () => {
		renderAt("/onboard/heard", SAAS);
		fireEvent.click(screen.getByRole("button", { name: /sign out/iu }));
		expect(logout).toHaveBeenCalled();
	});
});

// The blind spot this closes: dgonzalez hit the onboarding wall, came back
// two days later, hit it again, and left with zero notes — and nothing
// recorded any of it. `onboarding_step_viewed` is the minimum signal that
// would have shown someone stuck on one step across two visits.
describe("OnboardLayout step tracking", () => {
	afterEach(() => {
		mockTrack.mockClear();
	});

	it("emits onboarding_step_viewed for the step named by the URL", () => {
		renderAt("/onboard/agreement", SAAS);
		expect(mockTrack).toHaveBeenCalledWith("onboarding_step_viewed", { step: "agreement" });
	});

	it("does not re-fire on a re-render of the same step", () => {
		const { rerender } = renderAt("/onboard/heard", SAAS);
		expect(mockTrack).toHaveBeenCalledTimes(1);
		rerender(
			<MemoryRouter initialEntries={["/onboard/heard"]}>
				<Routes>
					<Route element={<OnboardLayout />}>
						<Route path="/onboard/heard" element={<p>heard step</p>} />
					</Route>
				</Routes>
			</MemoryRouter>,
		);
		expect(mockTrack).toHaveBeenCalledTimes(1);
	});

	it("does not emit for a step outside the account's chain (redirected before rendering)", () => {
		renderAt("/onboard/agreement", SELF);
		expect(mockTrack).not.toHaveBeenCalled();
	});
});
