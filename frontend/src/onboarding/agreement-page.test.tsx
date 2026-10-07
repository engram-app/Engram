import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import { LocaleProvider } from "@/i18n/locale-provider";
import { track } from "../analytics/track";
import AgreementPage from "./agreement-page";

vi.mock("../analytics/track", () => ({ track: vi.fn() }));
const mockTrack = vi.mocked(track);

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

	it("emits onboarding_step_completed for the agreement step on submit", async () => {
		mockTrack.mockClear();
		renderPage();
		fireEvent.click(screen.getByRole("checkbox", { name: /agree/iu }));
		fireEvent.click(screen.getByRole("button", { name: /continue/iu }));

		await waitFor(() =>
			expect(mockTrack).toHaveBeenCalledWith(
				"onboarding_step_completed",
				expect.objectContaining({ step: "agreement" }),
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

describe("AgreementPage: consent chrome is translated, the legal body is not", () => {
	const german = {
		de: async () => ({
			default: {
				"Please read the full agreement below before continuing. Our {privacy} (reviewed at signup) describes how we handle your data.":
					"Lies die vollständige Vereinbarung unten, bevor du fortfährst. Unsere {privacy} (bei der Anmeldung geprüft) beschreibt, wie wir deine Daten behandeln.",
				"privacy notice": "Datenschutzhinweis",
				"I have read and agree to the Terms of Service and Privacy Policy":
					"Ich habe die Nutzungsbedingungen und die Datenschutzerklärung gelesen und stimme zu",
				"I have read and agree to the agreement shown above and the privacy notice":
					"Ich habe die oben gezeigte Vereinbarung und den Datenschutzhinweis gelesen und stimme zu",
			},
		}),
	};

	afterEach(() => window.localStorage.clear());

	it("translates the intro, the privacy link and the checkbox", async () => {
		window.localStorage.setItem("engram:locale", "de");
		const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
		render(
			<LocaleProvider loaders={german}>
				<QueryClientProvider client={qc}>
					<MemoryRouter>
						<AgreementPage />
					</MemoryRouter>
				</QueryClientProvider>
			</LocaleProvider>,
		);
		expect(await screen.findByRole("link", { name: "Datenschutzhinweis" })).toBeInTheDocument();
		expect(screen.getByText(/Lies die vollständige Vereinbarung/u)).toBeInTheDocument();
		expect(
			screen.getByRole("checkbox", { name: /Ich habe die Nutzungsbedingungen/u }),
		).toBeInTheDocument();
		expect(screen.getByText(/Ich habe die oben gezeigte Vereinbarung/u)).toBeInTheDocument();
	});
});
