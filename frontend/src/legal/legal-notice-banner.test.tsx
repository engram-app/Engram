import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import { LegalNoticeBanner } from "./legal-notice-banner";

const { mutate, statusRef } = vi.hoisted(() => ({
	mutate: vi.fn().mockResolvedValue({ version: "2026-05-19", accepted_at: "now" }),
	statusRef: { current: {} as Record<string, unknown> },
}));

vi.mock("../api/queries", () => ({
	useAcceptTerms: () => ({ mutateAsync: mutate, isPending: false }),
	useOnboardingStatus: () => ({ data: statusRef.current, isLoading: false }),
}));

const privacyNotice = {
	document: "privacy_policy",
	version: "2026-10-12",
	effective_date: "2026-11-11",
	material: false,
	changelog: "App analytics now linked to your account.",
	url: "https://engram.page/privacy",
	accept_url: "https://app.engram.page/onboard/agreement",
};

function status(notices: unknown[]) {
	statusRef.current = {
		current_tos_version: "2026-05-19",
		current_privacy_version: "2026-10-12",
		legal_notices: notices,
	};
}

function renderBanner() {
	return render(
		<MemoryRouter>
			<LegalNoticeBanner />
		</MemoryRouter>,
	);
}

afterEach(() => mutate.mockClear());

describe("LegalNoticeBanner", () => {
	it("renders nothing without a pending notice", () => {
		status([]);
		const { container } = renderBanner();
		expect(container).toBeEmptyDOMElement();
	});

	it("shows what changed, when, and a link to the document", () => {
		status([privacyNotice]);
		renderBanner();
		expect(
			screen.getByText(/Privacy Policy update, effective November 11, 2026/u),
		).toBeInTheDocument();
		expect(screen.getByText(/App analytics now linked to your account/u)).toBeInTheDocument();
		expect(screen.getByRole("link", { name: /read it/iu })).toHaveAttribute(
			"href",
			"https://engram.page/privacy",
		);
	});

	it("a notice-only change is dismissed by recording the current versions", async () => {
		status([privacyNotice]);
		renderBanner();
		const button = screen.getByRole("button", { name: /got it/iu });
		await waitFor(() => expect(button).toBeEnabled());
		fireEvent.click(button);
		await waitFor(() =>
			expect(mutate).toHaveBeenCalledWith(
				expect.objectContaining({ tos_version: "2026-05-19", privacy_version: "2026-10-12" }),
			),
		);
	});

	// 2026-10-14 is current but silent; the banner shows 2026-10-12's change,
	// so that is the version "Got it" accepts.
	it("records acceptance of the version the banner showed, not the current one", async () => {
		status([privacyNotice]);
		statusRef.current.current_privacy_version = "2026-10-14";
		renderBanner();
		const button = screen.getByRole("button", { name: /got it/iu });
		await waitFor(() => expect(button).toBeEnabled());
		fireEvent.click(button);
		await waitFor(() =>
			expect(mutate).toHaveBeenCalledWith(
				expect.objectContaining({ privacy_version: "2026-10-12" }),
			),
		);
	});

	it("a material change cannot be dismissed, only reviewed and accepted", () => {
		status([{ ...privacyNotice, document: "terms_of_service", material: true }]);
		renderBanner();
		expect(screen.queryByRole("button", { name: /got it/iu })).toBeNull();
		expect(screen.getByRole("link", { name: /review and accept/iu })).toHaveAttribute(
			"href",
			"/onboard/agreement",
		);
	});
});
