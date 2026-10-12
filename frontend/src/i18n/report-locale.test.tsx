import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, waitFor } from "@testing-library/react";
import posthog from "posthog-js";
import type { ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "../api/client";
import { LocaleProvider } from "./locale-provider";
import { useReportLocale } from "./report-locale";

vi.mock("../api/client", () => ({
	api: { get: vi.fn(), post: vi.fn(), patch: vi.fn(), del: vi.fn() },
	setTokenGetter: vi.fn(),
}));
vi.mock("posthog-js", () => ({ default: { setPersonProperties: vi.fn() } }));

const get = vi.mocked(api.get);
const patch = vi.mocked(api.patch);

function user(locale: string | null) {
	return {
		user: {
			id: "u",
			email: "a@b.c",
			role: "member",
			display_name: null,
			analytics_id: "x",
			locale,
		},
	};
}

function Probe() {
	useReportLocale();
	return null;
}

function renderWith(stored: string | null): void {
	if (stored) {
		window.localStorage.setItem("engram:locale", stored);
	}
	const qc = new QueryClient({
		defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
	});
	const wrap = (children: ReactNode) => (
		<QueryClientProvider client={qc}>
			<LocaleProvider loaders={{}}>{children}</LocaleProvider>
		</QueryClientProvider>
	);
	render(wrap(<Probe />));
}

beforeEach(() => {
	get.mockReset();
	patch.mockReset();
	vi.mocked(posthog.setPersonProperties).mockClear();
	patch.mockImplementation((_path, body) =>
		Promise.resolve(user((body as { locale: string }).locale)),
	);
});
afterEach(() => window.localStorage.clear());

describe("useReportLocale", () => {
	it("stores the chosen locale on the account when it differs", async () => {
		get.mockResolvedValue(user(null));
		renderWith("de");
		await waitFor(() => expect(patch).toHaveBeenCalledWith("/me", { locale: "de" }));
	});

	it("sends nothing when the account already has it", async () => {
		get.mockResolvedValue(user("de"));
		renderWith("de");
		await waitFor(() => expect(get).toHaveBeenCalled());
		await new Promise((r) => setTimeout(r, 20));
		expect(patch).not.toHaveBeenCalled();
	});

	it("tags the analytics person with the locale", async () => {
		get.mockResolvedValue(user("ja"));
		renderWith("ja");
		await waitFor(() => expect(posthog.setPersonProperties).toHaveBeenCalledWith({ locale: "ja" }));
	});

	it("does not retry forever when the update fails", async () => {
		get.mockResolvedValue(user(null));
		patch.mockRejectedValue(new Error("422"));
		renderWith("fr");
		await waitFor(() => expect(patch).toHaveBeenCalledTimes(1));
		await new Promise((r) => setTimeout(r, 20));
		expect(patch).toHaveBeenCalledTimes(1);
	});
});
