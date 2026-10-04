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

const gotIt = () => screen.findByRole("button", { name: "Got it" });
const gone = () => screen.queryByRole("button", { name: "Turn off" });

describe("TelemetryPrompt", () => {
	it("tells a self-host admin who has not acknowledged it", async () => {
		render(<TelemetryPrompt />);

		expect(await gotIt()).toBeTruthy();
		expect(screen.getByRole("button", { name: "Turn off" })).toBeTruthy();
		expect(screen.queryByRole("button", { name: "Ask me later" })).toBeNull();
	});

	it("never calls the admin API on a Clerk (SaaS) instance", async () => {
		mockProvider = "clerk";
		render(<TelemetryPrompt />);

		await Promise.resolve();
		expect(mockGet).not.toHaveBeenCalled();
		expect(gone()).toBeNull();
	});

	it("never calls the admin API for a non-admin", async () => {
		mockRole = "member";
		render(<TelemetryPrompt />);

		await Promise.resolve();
		expect(mockGet).not.toHaveBeenCalled();
		expect(gone()).toBeNull();
	});

	it.each([true, false])("stays quiet once answered (%s)", async (answered) => {
		mockGet.mockResolvedValue(state({ telemetry_enabled: answered }));
		render(<TelemetryPrompt />);

		await waitFor(() => expect(mockGet).toHaveBeenCalled());
		expect(gone()).toBeNull();
	});

	it("stays quiet when the environment forbids telemetry", async () => {
		mockGet.mockResolvedValue(state({ env_disabled: true }));
		render(<TelemetryPrompt />);

		await waitFor(() => expect(mockGet).toHaveBeenCalled());
		expect(gone()).toBeNull();
	});

	it("'Got it' records an acknowledgement and goes away", async () => {
		mockSet.mockResolvedValue(state({ telemetry_enabled: true }));
		render(<TelemetryPrompt />);

		fireEvent.click(await gotIt());

		await waitFor(() => expect(mockSet).toHaveBeenCalledWith(true));
		await waitFor(() => expect(gone()).toBeNull());
	});

	it("'Turn off' records the refusal and goes away", async () => {
		mockSet.mockResolvedValue(state({ telemetry_enabled: false }));
		render(<TelemetryPrompt />);

		fireEvent.click(await screen.findByRole("button", { name: "Turn off" }));

		await waitFor(() => expect(mockSet).toHaveBeenCalledWith(false));
		await waitFor(() => expect(gone()).toBeNull());
	});

	it("stays on screen when saving fails", async () => {
		mockSet.mockRejectedValue(new Error("boom"));
		render(<TelemetryPrompt />);

		fireEvent.click(await gotIt());

		await waitFor(() => expect(mockSet).toHaveBeenCalled());
		expect(await gotIt()).toBeTruthy();
	});
});
