import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import type React from "react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { OnboardingStatus } from "../api/queries";
import OnboardAboutPage from "./onboard-about-page";

vi.mock("../analytics/track", () => ({ track: vi.fn() }));

const mutateAsync = vi.fn();
const mockNavigate = vi.fn();
let isError = false;

vi.mock("react-router", async () => {
	const actual = await vi.importActual<typeof import("react-router")>("react-router");
	return { ...actual, useNavigate: () => mockNavigate };
});

let status: OnboardingStatus;

vi.mock("../api/queries", async () => {
	const actual = await vi.importActual<typeof import("../api/queries")>("../api/queries");
	return {
		...actual,
		useOnboardingStatus: () => ({ data: status, isLoading: false }),
		useSubmitFeedback: () => ({ mutateAsync, isPending: false, isError }),
	};
});

function wrap(ui: React.ReactNode) {
	const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return (
		<QueryClientProvider client={qc}>
			<MemoryRouter>{ui}</MemoryRouter>
		</QueryClientProvider>
	);
}

beforeEach(() => {
	mutateAsync.mockReset().mockResolvedValue({ status: "ok" });
	mockNavigate.mockClear();
	isError = false;
	status = {
		enabled: true,
		next_step: "about",
		gate_ok: false,
		steps: ["agreement", "billing", "tools", "about", "vault"],
		actions: [],
		vault_count: 0,
		profile: { uses_obsidian: false, tools: ["claude"] },
	} as unknown as OnboardingStatus;
});

describe("OnboardAboutPage", () => {
	it("sends the answers, then moves on to vault", async () => {
		render(wrap(<OnboardAboutPage />));

		fireEvent.click(screen.getByRole("radio", { name: /reddit/iu }));
		fireEvent.click(screen.getByRole("checkbox", { name: /sync obsidian across devices/iu }));
		fireEvent.click(screen.getByRole("checkbox", { name: /something else/iu }));
		fireEvent.change(screen.getByLabelText(/tell us more/iu), {
			target: { value: "a team wiki" },
		});
		fireEvent.click(screen.getByRole("radio", { name: /somewhere else/iu }));
		const [, heardBox] = screen.getAllByLabelText(/tell us more/iu);
		fireEvent.change(heardBox, { target: { value: "a podcast" } });
		fireEvent.click(screen.getByRole("button", { name: /continue/iu }));

		await waitFor(() =>
			expect(mockNavigate).toHaveBeenCalledWith("/onboard/vault", { replace: true }),
		);
		expect(mutateAsync).toHaveBeenCalledWith({
			kind: "onboarding",
			heard_from: "other",
			use_cases: ["obsidian_sync", "other"],
			use_cases_detail: "a team wiki",
			heard_from_detail: "a podcast",
		});
	});

	it("Skip records an empty answer, then moves on", async () => {
		render(wrap(<OnboardAboutPage />));
		fireEvent.click(screen.getByRole("radio", { name: /reddit/iu }));
		fireEvent.click(screen.getByRole("button", { name: /skip/iu }));

		await waitFor(() =>
			expect(mockNavigate).toHaveBeenCalledWith("/onboard/vault", { replace: true }),
		);
		expect(mutateAsync).toHaveBeenCalledWith({ kind: "onboarding" });
	});

	it("Continue with nothing picked counts as a skip", async () => {
		render(wrap(<OnboardAboutPage />));
		fireEvent.click(screen.getByRole("button", { name: /continue/iu }));

		await waitFor(() => expect(mockNavigate).toHaveBeenCalled());
		expect(mutateAsync).toHaveBeenCalledWith({ kind: "onboarding" });
	});

	it("stays put and shows an error when saving fails", async () => {
		mutateAsync.mockRejectedValue(new Error("boom"));
		isError = true;
		render(wrap(<OnboardAboutPage />));
		fireEvent.click(screen.getByRole("button", { name: /skip/iu }));

		expect(await screen.findByRole("alert")).toBeInTheDocument();
		expect(mockNavigate).not.toHaveBeenCalled();
	});

	it("gives each question its own detail box, shown once its Other is picked", () => {
		render(wrap(<OnboardAboutPage />));
		expect(screen.queryByLabelText(/tell us more/iu)).toBeNull();

		fireEvent.click(screen.getByRole("checkbox", { name: /something else/iu }));
		const useCases = screen.getByRole("group", { name: /use engram for/iu });
		expect(within(useCases).getByLabelText(/tell us more/iu)).toBeInTheDocument();
		expect(screen.getAllByLabelText(/tell us more/iu)).toHaveLength(1);

		fireEvent.click(screen.getByRole("radio", { name: /somewhere else/iu }));
		const heard = screen.getByRole("group", { name: /hear about engram/iu });
		expect(within(heard).getByLabelText(/tell us more/iu)).toBeInTheDocument();
	});

	it("drops a detail whose Other was unpicked", async () => {
		render(wrap(<OnboardAboutPage />));
		const other = screen.getByRole("checkbox", { name: /something else/iu });
		fireEvent.click(other);
		fireEvent.change(screen.getByLabelText(/tell us more/iu), { target: { value: "x" } });
		fireEvent.click(other);
		fireEvent.click(screen.getByRole("radio", { name: /reddit/iu }));
		fireEvent.click(screen.getByRole("button", { name: /continue/iu }));

		await waitFor(() =>
			expect(mutateAsync).toHaveBeenCalledWith({ kind: "onboarding", heard_from: "reddit" }),
		);
	});
});
