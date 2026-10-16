import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { LocaleProvider } from "@/i18n/locale-provider";
import { track } from "../analytics/track";
import AgreementPage from "./agreement-page";

// The behaviour under test is the page, not the legal texts: rendering the
// full vendored markdown cost ~1s per test on an idle box and blew the 5s
// limit on CI runners. Short stand-ins keep the headings and dates asserted.
vi.mock("../legal/load", async (importOriginal) => ({
	...(await importOriginal<typeof import("../legal/load")>()),
	loadVersion: async (doc: "terms" | "privacy") =>
		doc === "terms"
			? "# Terms of Service\n\nLast updated: May 19, 2026\n\nStand-in text."
			: "# Privacy Policy\n\nLast updated: June 20, 2026\n\nStand-in text.",
}));

vi.mock("../analytics/track", () => ({ track: vi.fn() }));
const mockTrack = vi.mocked(track);

const { mutate, submitFeedback, statusRef } = vi.hoisted(() => ({
	mutate: vi.fn().mockResolvedValue({ version: "2026-05-19", accepted_at: "now" }),
	submitFeedback: vi.fn().mockResolvedValue({ status: "ok" }),
	statusRef: {
		current: {
			enabled: true,
			next_step: "agreement",
			current_tos_version: "2026-05-19",
			current_privacy_version: "2026-06-20",
			// A returning account re-accepting: not asked how it heard about us.
			profile: { completed_at: "2026-05-19T00:00:00Z" },
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
	useSubmitFeedback: () => ({ mutateAsync: submitFeedback, isPending: false }),
}));

// The legal texts load as lazy chunks; Continue enables once both have. A
// chunk import on a loaded CI runner takes longer than waitFor's 1s default.
async function clickContinue() {
	const button = screen.getByRole("button", { name: /continue/iu });
	await waitFor(() => expect(button).toBeEnabled(), { timeout: 10_000 });
	fireEvent.click(button);
}

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

// The legal texts and their renderer are lazy chunks. Their first import in a
// file pays Vite's transform, which on a busy CI runner outlasts the 1s that
// findBy/waitFor allow. Loaded once up front, the tests time behaviour only.
beforeAll(async () => {
	const { loadVersion, renderableVersion } = await import("../legal/load");
	await Promise.all(
		(["terms", "privacy"] as const).map((doc) => {
			const version = renderableVersion(doc, "9999-12-31");
			return version ? loadVersion(doc, version) : undefined;
		}),
	);
	await import("../legal/legal-doc");
});

describe("AgreementPage", () => {
	it("disables Continue until the agreement checkbox is checked", async () => {
		renderPage();
		const button = screen.getByRole("button", { name: /continue/iu });
		// Wait for the lazily loaded texts, so only the checkbox gates it.
		await screen.findByRole("heading", { name: /Terms of Service/iu });
		expect(button).toBeDisabled();

		fireEvent.click(screen.getByRole("checkbox", { name: /agree/iu }));
		await waitFor(() => expect(button).not.toBeDisabled());
	});

	it("submits the new version+hash object shape on continue", async () => {
		renderPage();
		fireEvent.click(screen.getByRole("checkbox", { name: /agree/iu }));
		await clickContinue();

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
		expect(await screen.findByRole("heading", { name: /Terms of Service/iu })).toBeInTheDocument();
		fireEvent.click(screen.getByRole("checkbox", { name: /agree/iu }));
		await clickContinue();
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
		await clickContinue();

		await waitFor(() =>
			expect(mockTrack).toHaveBeenCalledWith(
				"onboarding_step_completed",
				expect.objectContaining({ step: "agreement" }),
			),
		);
	});

	// The public privacy page is unversioned, so it can differ from the text
	// whose hash is recorded. The page shows the exact version it accepts.
	it("shows the privacy version being accepted in-app, not a link", async () => {
		renderPage();
		const toggle = screen.getByRole("button", { name: /privacy notice/iu });
		expect(screen.queryByRole("heading", { name: /Privacy Policy/iu })).toBeNull();
		fireEvent.click(toggle);
		expect(await screen.findByRole("heading", { name: /Privacy Policy/iu })).toBeInTheDocument();
		expect(screen.getByText(/June 20, 2026/u)).toBeInTheDocument();
		expect(toggle).toHaveAttribute("aria-expanded", "true");
		expect(screen.queryByRole("link", { name: /^privacy notice$/iu })).toBeNull();
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
		expect(await screen.findByRole("button", { name: "Datenschutzhinweis" })).toBeInTheDocument();
		expect(screen.getByText(/Lies die vollständige Vereinbarung/u)).toBeInTheDocument();
		expect(
			screen.getByRole("checkbox", { name: /Ich habe die Nutzungsbedingungen/u }),
		).toBeInTheDocument();
		expect(screen.getByText(/Ich habe die oben gezeigte Vereinbarung/u)).toBeInTheDocument();
	});

	it("lists what changed when a legal change is pending", () => {
		statusRef.current = {
			...DEFAULT_STATUS,
			legal_notices: [
				{
					document: "privacy_policy",
					version: "2026-10-12",
					effective_date: "2026-11-11",
					material: false,
					changelog: "App analytics now linked to your account.",
					url: "https://engram.page/privacy",
					accept_url: "https://app.engram.page/onboard/agreement",
				},
			],
		};
		renderPage();
		expect(screen.getByRole("heading", { name: /what changed/iu })).toBeInTheDocument();
		expect(screen.getByText(/Privacy Policy, effective November 11, 2026:/u)).toBeInTheDocument();
		expect(screen.getByText(/App analytics now linked to your account/u)).toBeInTheDocument();
	});
});

// "How did you hear about Engram?" is its own step (heard-page.tsx), so the
// terms screen never asks it, not even of a brand-new web signup.
describe("AgreementPage: terms only", () => {
	it("does not ask a new web signup how it heard about us", async () => {
		statusRef.current = { ...DEFAULT_STATUS, profile: undefined };
		renderPage();
		await screen.findByRole("heading", { name: /Terms of Service/iu });
		expect(screen.queryByText("How did you hear about Engram?")).not.toBeInTheDocument();
		expect(screen.queryByRole("radio")).toBeNull();
	});

	it("cannot be submitted twice while saving", async () => {
		let release: (v: unknown) => void = () => undefined;
		mutate.mockClear();
		mutate.mockImplementationOnce(
			() =>
				new Promise((r) => {
					release = r;
				}),
		);
		renderPage();
		await screen.findByRole("heading", { name: /Terms of Service/iu });
		fireEvent.click(screen.getByRole("checkbox", { name: /agree/iu }));
		await clickContinue();
		await waitFor(() => expect(mutate).toHaveBeenCalledTimes(1));

		const button = screen.getByRole("button", { name: /continue|saving/iu });
		expect(button).toBeDisabled();
		fireEvent.click(button);
		expect(mutate).toHaveBeenCalledTimes(1);
		release({ version: "2026-05-19", accepted_at: "now" });
	});
});
