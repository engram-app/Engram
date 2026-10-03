import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { TelemetryState } from "./api";
import TelemetryPrompt from "./TelemetryPrompt";

const payload = {
	id: "0192f3a0-7b1e-7c3a-9d2e-5a1b2c3d4e5f",
	version: "0.5.518",
	os: "linux",
	arch: "amd64",
	runtime: "docker",
};
const state = (over: Partial<TelemetryState> = {}): TelemetryState => ({
	telemetry_enabled: null,
	env_disabled: false,
	payload,
	...over,
});

let mockProvider = "local";
let mockRole: "admin" | "member" = "admin";
const mockGet = vi.fn();
const mockSet = vi.fn();

vi.mock("@/config-context", () => ({ useConfig: () => ({ authProvider: mockProvider }) }));
vi.mock("@/api/queries", () => ({ useMe: () => ({ data: { id: "u1", role: mockRole } }) }));
vi.mock("./api", () => ({
	adminApi: {
		getTelemetry: () => mockGet(),
		setTelemetry: (enabled: boolean) => mockSet(enabled),
	},
}));

beforeEach(() => {
	mockProvider = "local";
	mockRole = "admin";
	mockGet.mockReset().mockResolvedValue(state());
	mockSet.mockReset();
});

const share = () => screen.findByRole("button", { name: "Share anonymous stats" });

describe("TelemetryPrompt", () => {
	it("asks a self-host admin who has not answered", async () => {
		render(<TelemetryPrompt />);

		expect(await share()).toBeTruthy();
		expect(screen.getByRole("button", { name: "No thanks" })).toBeTruthy();
		expect(screen.getByRole("button", { name: "Ask me later" })).toBeTruthy();
	});

	it("never calls the admin API on a Clerk (SaaS) instance", async () => {
		mockProvider = "clerk";
		render(<TelemetryPrompt />);

		await Promise.resolve();
		expect(mockGet).not.toHaveBeenCalled();
		expect(screen.queryByRole("button", { name: "No thanks" })).toBeNull();
	});

	it("never calls the admin API for a non-admin", async () => {
		mockRole = "member";
		render(<TelemetryPrompt />);

		await Promise.resolve();
		expect(mockGet).not.toHaveBeenCalled();
		expect(screen.queryByRole("button", { name: "No thanks" })).toBeNull();
	});

	it.each([true, false])("stays quiet once answered (%s)", async (answered) => {
		mockGet.mockResolvedValue(state({ telemetry_enabled: answered }));
		render(<TelemetryPrompt />);

		await waitFor(() => expect(mockGet).toHaveBeenCalled());
		expect(screen.queryByRole("button", { name: "No thanks" })).toBeNull();
	});

	it("stays quiet when the environment forbids telemetry", async () => {
		mockGet.mockResolvedValue(state({ env_disabled: true }));
		render(<TelemetryPrompt />);

		await waitFor(() => expect(mockGet).toHaveBeenCalled());
		expect(screen.queryByRole("button", { name: "No thanks" })).toBeNull();
	});

	it("records yes and goes away", async () => {
		mockSet.mockResolvedValue(state({ telemetry_enabled: true }));
		render(<TelemetryPrompt />);

		fireEvent.click(await share());

		await waitFor(() => expect(mockSet).toHaveBeenCalledWith(true));
		await waitFor(() => expect(screen.queryByRole("button", { name: "No thanks" })).toBeNull());
	});

	it("records no and goes away", async () => {
		mockSet.mockResolvedValue(state({ telemetry_enabled: false }));
		render(<TelemetryPrompt />);

		fireEvent.click(await screen.findByRole("button", { name: "No thanks" }));

		await waitFor(() => expect(mockSet).toHaveBeenCalledWith(false));
		await waitFor(() => expect(screen.queryByRole("button", { name: "No thanks" })).toBeNull());
	});

	it("'Ask me later' hides it without recording an answer", async () => {
		render(<TelemetryPrompt />);

		fireEvent.click(await screen.findByRole("button", { name: "Ask me later" }));

		expect(screen.queryByRole("button", { name: "No thanks" })).toBeNull();
		expect(mockSet).not.toHaveBeenCalled();
	});

	it("stays on screen when saving fails", async () => {
		mockSet.mockRejectedValue(new Error("boom"));
		render(<TelemetryPrompt />);

		fireEvent.click(await share());

		await waitFor(() => expect(mockSet).toHaveBeenCalled());
		expect(await share()).toBeTruthy();
	});
});
