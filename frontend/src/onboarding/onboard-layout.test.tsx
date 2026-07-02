import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";
import { describe, expect, it, vi } from "vitest";
import { useOnboardingStatus } from "../api/queries";
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
