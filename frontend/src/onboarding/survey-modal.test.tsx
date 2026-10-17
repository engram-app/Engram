import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { OnboardingProfile } from "../api/queries";
import { SurveyModal, SurveyPrompt, surveyPending } from "./survey-modal";

const { submitFeedback, useVaultsSpy, state } = vi.hoisted(() => ({
	submitFeedback: vi.fn().mockResolvedValue({ status: "ok" }),
	useVaultsSpy: vi.fn(),
	state: {
		billingEnabled: true,
		status: { next_step: "done", profile: {} } as {
			next_step: string;
			profile?: OnboardingProfile;
		},
		vaults: [] as { populated?: boolean }[],
		connections: [] as { kind: string }[],
		actions: new Set<string>(),
		pending: false,
	},
}));

vi.mock("@/config-context", () => ({
	useConfig: () => ({ billingEnabled: state.billingEnabled }),
}));
vi.mock("../api/queries", () => ({
	useOnboardingStatus: () => ({ data: state.status }),
	useVaults: (opts?: { enabled?: boolean }) => {
		useVaultsSpy(opts);
		return { data: state.vaults };
	},
	useConnections: () => ({ data: state.connections }),
	useSubmitFeedback: () => ({ mutateAsync: submitFeedback, isPending: state.pending }),
}));
vi.mock("./use-onboarding-actions", () => ({
	useOnboardingActions: () => ({ has: (a: string) => state.actions.has(a) }),
}));

function renderUi(ui: React.ReactElement, path = "/") {
	const qc = new QueryClient();
	return render(
		<QueryClientProvider client={qc}>
			<MemoryRouter initialEntries={[path]}>{ui}</MemoryRouter>
		</QueryClientProvider>,
	);
}

beforeEach(() => {
	submitFeedback.mockClear();
	useVaultsSpy.mockClear();
	state.pending = false;
	state.billingEnabled = true;
	state.status = { next_step: "done", profile: {} };
	state.vaults = [];
	state.connections = [];
	state.actions = new Set();
});

describe("surveyPending", () => {
	it("is pending for a new account", () => {
		expect(surveyPending({})).toBe(true);
		expect(surveyPending({ tools: ["chatgpt"], tools_prefilled: true })).toBe(true);
		// The terms-screen heard-from answer stamps survey_done_at, not this.
		expect(surveyPending({ heard_from: "reddit", survey_done_at: "x" })).toBe(true);
	});

	it("is done once asked, or when the old wizard asked it", () => {
		expect(surveyPending({ use_cases_done_at: "x" })).toBe(false);
		expect(surveyPending({ use_cases: ["search"] })).toBe(false);
		expect(surveyPending({ tools: ["claude"] })).toBe(false);
	});
});

describe("SurveyPrompt", () => {
	const title = "Help us shape Engram";

	it("waits for first value", () => {
		renderUi(<SurveyPrompt suppressed={false} />);
		expect(screen.queryByText(title)).toBeNull();
	});

	it.each([
		["an AI tool connected", () => state.connections.push({ kind: "mcp" })],
		["the plugin linked", () => state.actions.add("plugin_connected")],
		["notes beyond the welcome note", () => state.vaults.push({ populated: true })],
	])("shows after %s", (_label, arrange) => {
		arrange();
		renderUi(<SurveyPrompt suppressed={false} />);
		expect(screen.getByText(title)).toBeInTheDocument();
	});

	// An API key is not a sign of value, and creating one invalidates the
	// connections query: counting it would open the survey over a key that
	// is shown only once.
	it("does not count an API key as first value", () => {
		state.connections.push({ kind: "pat" });
		renderUi(<SurveyPrompt suppressed={false} />);
		expect(screen.queryByText(title)).toBeNull();
	});

	it("stays out of the way while Settings is open", () => {
		state.connections.push({ kind: "mcp" });
		renderUi(<SurveyPrompt suppressed={false} />, "/#settings/connections");
		expect(screen.queryByText(title)).toBeNull();
	});

	// The vault list is only needed to decide whether to ask.
	it("does not read vaults for an account it will never ask", () => {
		state.status = { next_step: "done", profile: { use_cases_done_at: "2026-10-01" } };
		renderUi(<SurveyPrompt suppressed={false} />);
		expect(useVaultsSpy).toHaveBeenCalledWith({ enabled: false });
	});

	it("never shows on self-host, mid-wizard, or while suppressed", () => {
		state.connections.push({ kind: "mcp" });

		state.billingEnabled = false;
		const { unmount } = renderUi(<SurveyPrompt suppressed={false} />);
		expect(screen.queryByText(title)).toBeNull();
		unmount();

		state.billingEnabled = true;
		state.status = { next_step: "vault", profile: {} };
		const second = renderUi(<SurveyPrompt suppressed={false} />);
		expect(screen.queryByText(title)).toBeNull();
		second.unmount();

		state.status = { next_step: "done", profile: {} };
		renderUi(<SurveyPrompt suppressed />);
		expect(screen.queryByText(title)).toBeNull();
	});
});

describe("SurveyModal", () => {
	it("pre-selects the connector's tool and saves tools plus use cases", async () => {
		const onDone = vi.fn();
		renderUi(<SurveyModal initialTools={["chatgpt"]} onDone={onDone} />);

		expect(screen.getByRole("checkbox", { name: "ChatGPT" })).toBeChecked();
		fireEvent.click(screen.getByRole("checkbox", { name: "Claude" }));
		fireEvent.click(screen.getByRole("checkbox", { name: "AI memory" }));
		fireEvent.click(screen.getByRole("button", { name: "Save" }));

		await waitFor(() => expect(onDone).toHaveBeenCalled());
		// One request carries both answers.
		expect(submitFeedback).toHaveBeenCalledTimes(1);
		expect(submitFeedback).toHaveBeenCalledWith({
			kind: "onboarding",
			use_cases: ["ai_memory"],
			tools: ["chatgpt", "claude"],
		});
	});

	it("sends no tools when none are picked", async () => {
		const onDone = vi.fn();
		renderUi(<SurveyModal initialTools={[]} onDone={onDone} />);
		fireEvent.click(screen.getByRole("button", { name: "Save" }));

		await waitFor(() => expect(onDone).toHaveBeenCalled());
		expect(submitFeedback).toHaveBeenCalledWith({ kind: "onboarding", use_cases: [] });
	});

	it("Skip stamps the survey as asked and closes", () => {
		const onDone = vi.fn();
		renderUi(<SurveyModal initialTools={[]} onDone={onDone} />);
		fireEvent.click(screen.getByRole("button", { name: "Skip" }));

		expect(submitFeedback).toHaveBeenCalledWith({ kind: "onboarding", use_cases: [] });
		expect(onDone).toHaveBeenCalled();
	});

	// Escape while Save is in flight would send a skip with no answers.
	it("ignores a close while saving", () => {
		state.pending = true;
		const onDone = vi.fn();
		renderUi(<SurveyModal initialTools={[]} onDone={onDone} />);
		fireEvent.keyDown(screen.getByRole("dialog"), { key: "Escape" });

		expect(submitFeedback).not.toHaveBeenCalled();
		expect(onDone).not.toHaveBeenCalled();
	});

	it("shows the close as busy while saving", () => {
		state.pending = true;
		renderUi(<SurveyModal initialTools={[]} onDone={vi.fn()} />);
		expect(screen.getByRole("button", { name: "Close" })).toBeDisabled();
	});

	// A failed save must not trap them: closing then skips as usual.
	it("lets them close after a failed save", async () => {
		submitFeedback.mockRejectedValueOnce(new Error("boom"));
		const onDone = vi.fn();
		renderUi(<SurveyModal initialTools={[]} onDone={onDone} />);
		fireEvent.click(screen.getByRole("button", { name: "Save" }));
		await screen.findByRole("alert");
		fireEvent.keyDown(screen.getByRole("dialog"), { key: "Escape" });
		expect(onDone).toHaveBeenCalled();
	});

	it("stays open with an error when saving fails", async () => {
		submitFeedback.mockRejectedValueOnce(new Error("boom"));
		const onDone = vi.fn();
		renderUi(<SurveyModal initialTools={[]} onDone={onDone} />);
		fireEvent.click(screen.getByRole("button", { name: "Save" }));

		expect(await screen.findByRole("alert")).toBeInTheDocument();
		expect(onDone).not.toHaveBeenCalled();
	});
});
