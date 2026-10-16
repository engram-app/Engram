import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import { track } from "../analytics/track";
import HeardPage from "./heard-page";

vi.mock("../analytics/track", () => ({ track: vi.fn() }));
const mockTrack = vi.mocked(track);

const { submitFeedback } = vi.hoisted(() => ({
	submitFeedback: vi.fn().mockResolvedValue({ status: "ok" }),
}));

vi.mock("../api/queries", () => ({
	useSubmitFeedback: () => ({ mutateAsync: submitFeedback, isPending: false }),
}));

afterEach(() => {
	vi.clearAllMocks();
	submitFeedback.mockResolvedValue({ status: "ok" });
});

function Probe() {
	return <p data-testid="probe">{useLocation().pathname}</p>;
}

function renderPage() {
	const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return render(
		<QueryClientProvider client={qc}>
			<MemoryRouter initialEntries={["/onboard/heard"]}>
				<Probe />
				<HeardPage />
			</MemoryRouter>
		</QueryClientProvider>,
	);
}

describe("HeardPage", () => {
	it("requires an answer before Continue", () => {
		renderPage();
		expect(screen.getByRole("heading", { name: "How did you hear about Engram?" })).toBeVisible();
		expect(screen.getByText("Pick one to continue.")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: /continue/iu })).toBeDisabled();
	});

	it("saves the answer and moves on", async () => {
		renderPage();
		fireEvent.click(screen.getByRole("radio", { name: "Reddit" }));
		fireEvent.click(screen.getByRole("button", { name: /continue/iu }));

		await waitFor(() =>
			expect(submitFeedback).toHaveBeenCalledWith({ kind: "onboarding", heard_from: "reddit" }),
		);
		await waitFor(() => expect(screen.getByTestId("probe")).toHaveTextContent(/^\/onboard$/u));
		expect(mockTrack).toHaveBeenCalledWith(
			"onboarding_step_completed",
			expect.objectContaining({ step: "heard" }),
		);
	});

	it("sends the detail only for Somewhere else", async () => {
		renderPage();
		fireEvent.click(screen.getByRole("radio", { name: "Somewhere else" }));
		fireEvent.change(screen.getByRole("textbox"), { target: { value: "  a podcast " } });
		fireEvent.click(screen.getByRole("button", { name: /continue/iu }));

		await waitFor(() =>
			expect(submitFeedback).toHaveBeenCalledWith({
				kind: "onboarding",
				heard_from: "other",
				heard_from_detail: "a podcast",
			}),
		);
	});

	// The backend keeps the wizard on this step until the answer is saved, so
	// moving on after a failed save would bounce straight back here.
	it("stays and says so when the save fails", async () => {
		submitFeedback.mockRejectedValueOnce(new Error("429"));
		renderPage();
		fireEvent.click(screen.getByRole("radio", { name: "Reddit" }));
		fireEvent.click(screen.getByRole("button", { name: /continue/iu }));

		expect(await screen.findByRole("alert")).toHaveTextContent(
			"Couldn't save your answers, please try again.",
		);
		expect(screen.getByTestId("probe")).toHaveTextContent("/onboard/heard");
		expect(screen.getByRole("button", { name: /continue/iu })).toBeEnabled();
	});
});
