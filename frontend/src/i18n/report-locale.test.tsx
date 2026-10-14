import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, render, screen, waitFor } from "@testing-library/react";
import posthog from "posthog-js";
import type { ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError, api } from "../api/client";
import { useMe, useUpdateProfile } from "../api/queries";
import { LocaleProvider } from "./locale-provider";
import { useReportLocale } from "./report-locale";

vi.mock("../api/client", async (orig) => ({
	ApiError: (await orig<typeof import("../api/client")>()).ApiError,
	api: { get: vi.fn(), post: vi.fn(), patch: vi.fn(), del: vi.fn() },
	setTokenGetter: vi.fn(),
}));
vi.mock("posthog-js", () => ({
	default: { __loaded: true, has_opted_out_capturing: () => false, setPersonProperties: vi.fn() },
}));

const get = vi.mocked(api.get);
const patch = vi.mocked(api.patch);

function user(locale: string | null, extra: Record<string, unknown> = {}) {
	return {
		user: {
			id: "u",
			email: "a@b.c",
			role: "member" as const,
			display_name: null,
			analytics_id: "x",
			analytics_opt_out: false,
			locale,
			...extra,
		},
	};
}

function Probe() {
	useReportLocale();
	return <>{useMe().data?.display_name}</>;
}

function renderWith(stored: string | null): QueryClient {
	if (stored) {
		window.localStorage.setItem("engram:locale", stored);
	}
	const qc = new QueryClient({
		defaultOptions: { queries: { retry: false }, mutations: { retryDelay: 0 } },
	});
	const wrap = (children: ReactNode) => (
		<QueryClientProvider client={qc}>
			<LocaleProvider loaders={{}}>{children}</LocaleProvider>
		</QueryClientProvider>
	);
	render(wrap(<Probe />));
	return qc;
}

// The PATCH effect runs in the same commit as, and before, the PostHog one, so
// once PostHog is tagged the PATCH decision has been made: no timing guess.
const tagged = () => waitFor(() => expect(posthog.setPersonProperties).toHaveBeenCalled());
const settled = (qc: QueryClient) =>
	waitFor(() => expect(qc.getMutationCache().getAll()[0]?.state.status).toBe("error"));

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
		await tagged();
		expect(patch).not.toHaveBeenCalled();
	});

	it("tags the analytics person with the locale", async () => {
		get.mockResolvedValue(user("ja"));
		renderWith("ja");
		await waitFor(() => expect(posthog.setPersonProperties).toHaveBeenCalledWith({ locale: "ja" }));
	});

	it("does not retry a rejected locale", async () => {
		get.mockResolvedValue(user(null));
		patch.mockRejectedValue(new ApiError(422, "bad locale"));
		const qc = renderWith("fr");
		await settled(qc);
		expect(patch).toHaveBeenCalledTimes(1);
	});

	it("retries a transient failure a bounded number of times", async () => {
		get.mockResolvedValue(user(null));
		patch.mockRejectedValue(new ApiError(503, "down"));
		const qc = renderWith("fr");
		await settled(qc);
		expect(patch).toHaveBeenCalledTimes(3);
	});

	it("never tags a user who opted out of analytics", async () => {
		get.mockResolvedValue(user(null, { analytics_opt_out: true }));
		renderWith("ja");
		await waitFor(() => expect(patch).toHaveBeenCalled());
		expect(posthog.setPersonProperties).not.toHaveBeenCalled();
	});

	it("re-tags only when the locale changes, not on other profile edits", async () => {
		get.mockResolvedValue(user("ja"));
		const qc = renderWith("ja");
		await tagged();
		act(() => qc.setQueryData(["me"], user("ja", { display_name: "Ada" })));
		await screen.findByText("Ada");
		expect(posthog.setPersonProperties).toHaveBeenCalledTimes(1);
	});
});

describe("useUpdateProfile", () => {
	it("a slower response does not undo a newer edit to another field", async () => {
		const qc = new QueryClient();
		qc.setQueryData(["me"], user(null, { display_name: "New" }));
		patch.mockResolvedValue(user("de", { display_name: "Old" }));
		let mutate: ReturnType<typeof useUpdateProfile>["mutateAsync"] = async () => user(null);
		function Grab() {
			mutate = useUpdateProfile().mutateAsync;
			return null;
		}
		render(
			<QueryClientProvider client={qc}>
				<Grab />
			</QueryClientProvider>,
		);
		await act(() => mutate({ locale: "de" }));
		expect(qc.getQueryData(["me"])).toMatchObject({ user: { locale: "de", display_name: "New" } });
	});
});
