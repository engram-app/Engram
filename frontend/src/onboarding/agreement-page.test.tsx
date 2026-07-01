import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import AgreementPage from "./agreement-page";

const { mutate, statusRef } = vi.hoisted(() => ({
	mutate: vi.fn().mockResolvedValue({ version: "2026-05-19", accepted_at: "now" }),
	statusRef: {
		current: {
			enabled: true,
			next_step: "agreement",
			current_tos_version: "2026-05-19",
			current_privacy_version: "2026-06-20",
		} as Record<string, unknown>,
	},
}));

const DEFAULT_STATUS = { ...statusRef.current };
afterEach(() => {
	statusRef.current = { ...DEFAULT_STATUS };
});

vi.mock("../api/queries", () => ({
	useAcceptTerms: () => ({ mutateAsync: mutate, isPending: false }),
	useOnboardingStatus: () => ({ data: statusRef.current, isLoading: false }),
}));

function renderPage() {
	const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return render(
		<QueryClientProvider client={qc}>
			<MemoryRouter>
				<AgreementPage />
			</MemoryRouter>
		</QueryClientProvider>,
	);
}

describe("AgreementPage", () => {
	it("disables Continue until the agreement checkbox is checked", () => {
		renderPage();
		const button = screen.getByRole("button", { name: /continue/iu });
		expect(button).toBeDisabled();

		fireEvent.click(screen.getByRole("checkbox", { name: /agree/iu }));
		expect(button).not.toBeDisabled();
	});

	it("submits the new version+hash object shape on continue", async () => {
		renderPage();
		fireEvent.click(screen.getByRole("checkbox", { name: /agree/iu }));
		fireEvent.click(screen.getByRole("button", { name: /continue/iu }));

		await waitFor(() =>
			expect(mutate).toHaveBeenCalledWith(
				expect.objectContaining({
					tos_version: "2026-05-19",
					privacy_version: "2026-06-20",
				}),
			),
		);
	});

	it("renders the ToS text inline and submits both versions with sha256 hashes", async () => {
		renderPage();
		// The vendored ToS markdown renders its own "# Terms of Service" heading
		// inline; assert against that heading specifically (the prose body repeats
		// the phrase in paragraphs, so an unscoped getByText would multi-match).
		expect(screen.getByRole("heading", { name: /Terms of Service/iu })).toBeInTheDocument();
		fireEvent.click(screen.getByRole("checkbox", { name: /agree/iu }));
		fireEvent.click(screen.getByRole("button", { name: /continue/iu }));
		await waitFor(() =>
			expect(mutate).toHaveBeenCalledWith(
				expect.objectContaining({
					tos_version: "2026-05-19",
					privacy_version: "2026-06-20",
					tos_hash: expect.stringMatching(/^[0-9a-f]{64}$/u),
					privacy_hash: expect.stringMatching(/^[0-9a-f]{64}$/u),
				}),
			),
		);
	});

	it("shows an error and disables continue when the backend names an unbundled version", () => {
		statusRef.current = {
			...DEFAULT_STATUS,
			current_tos_version: "2026-05-15",
			current_privacy_version: "2026-05-15",
		};
		renderPage();
		expect(screen.getByRole("alert")).toHaveTextContent(/isn.t available/iu);
		expect(screen.queryByRole("button", { name: /continue/iu })).toBeNull();
	});
});
