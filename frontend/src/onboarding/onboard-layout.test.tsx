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

type Steps = ("agreement" | "billing" | "tools" | "vault")[];

function renderAt(path: string, steps: Steps) {
	vi.mocked(useOnboardingStatus).mockReturnValue({
		data: { enabled: true, next_step: "tools", steps },
		isLoading: false,
		isError: false,
	} as never);

	return render(
		<MemoryRouter initialEntries={[path]}>
			<Routes>
				<Route element={<OnboardLayout />}>
					<Route path="/onboard/agreement" element={<p>agreement step</p>} />
					<Route path="/onboard/billing" element={<p>billing step</p>} />
					<Route path="/onboard/tools" element={<p>tools step</p>} />
					<Route path="/onboard/vault" element={<p>vault step</p>} />
				</Route>
				<Route path="/onboard" element={<p>resolver landing</p>} />
			</Routes>
		</MemoryRouter>,
	);
}

const SAAS: Steps = ["agreement", "billing", "tools", "vault"];
const SELF: Steps = ["tools", "vault"];

// Interrupting an OAuth flow for signup is fine, but it has to stay legible:
// the user should know whose authorization is waiting, and be able to refuse
// in a way the client actually hears (access_denied), rather than closing a
// tab the client waits on forever.
describe("OnboardLayout pending authorization", () => {
	const PARKED = "?redirect_uri=https://app/cb&state=xyz";

	afterEach(() => {
		window.sessionStorage.clear();
	});

	it("names the app that is waiting", () => {
		stashPendingAuthorization(PARKED, null, "Google Antigravity");

		renderAt("/onboard/tools", SAAS);

		expect(screen.getByText(/Google Antigravity/u)).toBeTruthy();
	});

	it("falls back to neutral wording for an unnamed client", () => {
		stashPendingAuthorization(PARKED, null, null);

		renderAt("/onboard/tools", SAAS);

		expect(screen.getByRole("button", { name: /cancel/iu })).toBeTruthy();
	});

	it("says nothing at all when no authorization is pending", () => {
		renderAt("/onboard/tools", SAAS);

		expect(screen.queryByRole("button", { name: /cancel/iu })).toBeNull();
	});

	it("reports access_denied to the client on cancel", () => {
		stashPendingAuthorization(PARKED, null, "Google Antigravity");
		const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});

		renderAt("/onboard/tools", SAAS);
		fireEvent.click(screen.getByRole("button", { name: /cancel/iu }));

		expect(assign).toHaveBeenCalledWith("https://app/cb?error=access_denied&state=xyz");
	});

	it("drops the parked request on cancel so it cannot resurface", () => {
		stashPendingAuthorization(PARKED, null, "Google Antigravity");
		vi.spyOn(window.location, "assign").mockImplementation(() => {});

		renderAt("/onboard/tools", SAAS);
		fireEvent.click(screen.getByRole("button", { name: /cancel/iu }));

		expect(window.sessionStorage.getItem("engram:pending-oauth")).toBeNull();
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
			<MemoryRouter initialEntries={["/onboard/tools"]}>
				<Routes>
					<Route element={<OnboardLayout />}>
						<Route path="/onboard/tools" element={<p>tools step</p>} />
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

	it("shows step 3 of 4 on tools (hosted)", () => {
		renderAt("/onboard/tools", SAAS);
		expect(screen.getByText(/step 3 of 4/iu)).toBeInTheDocument();
	});

	it("shows step 4 of 4 on vault (hosted)", () => {
		renderAt("/onboard/vault", SAAS);
		expect(screen.getByText(/step 4 of 4/iu)).toBeInTheDocument();
	});

	it("shows step 1 of 2 on tools (self-host)", () => {
		renderAt("/onboard/tools", SELF);
		expect(screen.getByText(/step 1 of 2/iu)).toBeInTheDocument();
	});

	it("shows step 2 of 2 on vault (self-host)", () => {
		renderAt("/onboard/vault", SELF);
		expect(screen.getByText(/step 2 of 2/iu)).toBeInTheDocument();
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
		renderAt("/onboard/tools", SAAS);
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
		const { rerender } = renderAt("/onboard/tools", SAAS);
		expect(mockTrack).toHaveBeenCalledTimes(1);
		rerender(
			<MemoryRouter initialEntries={["/onboard/tools"]}>
				<Routes>
					<Route element={<OnboardLayout />}>
						<Route path="/onboard/tools" element={<p>tools step</p>} />
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
