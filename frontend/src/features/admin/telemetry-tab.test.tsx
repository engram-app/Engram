import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { TelemetryState } from "./api";
import TelemetryTab from "./TelemetryTab";

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

const mockGet = vi.fn();
const mockSet = vi.fn();
vi.mock("./api", () => ({
	adminApi: {
		getTelemetry: () => mockGet(),
		setTelemetry: (enabled: boolean) => mockSet(enabled),
	},
}));

beforeEach(() => {
	mockGet.mockReset();
	mockSet.mockReset();
});

describe("TelemetryTab", () => {
	it("asks once when the operator has not answered", async () => {
		mockGet.mockResolvedValue(state());
		render(<TelemetryTab />);

		expect(await screen.findByRole("button", { name: "Share anonymous stats" })).toBeTruthy();
		expect(screen.getByRole("button", { name: "No thanks" })).toBeTruthy();
		expect(screen.queryByRole("checkbox")).toBeNull();
	});

	it("records yes and swaps the prompt for a checked toggle", async () => {
		mockGet.mockResolvedValue(state());
		mockSet.mockResolvedValue(state({ telemetry_enabled: true }));
		render(<TelemetryTab />);

		fireEvent.click(await screen.findByRole("button", { name: "Share anonymous stats" }));

		await waitFor(() => expect(mockSet).toHaveBeenCalledWith(true));
		const box = (await screen.findByRole("checkbox")) as HTMLInputElement;
		expect(box.checked).toBe(true);
		expect(screen.queryByRole("button", { name: "No thanks" })).toBeNull();
	});

	it("records no", async () => {
		mockGet.mockResolvedValue(state());
		mockSet.mockResolvedValue(state({ telemetry_enabled: false }));
		render(<TelemetryTab />);

		fireEvent.click(await screen.findByRole("button", { name: "No thanks" }));

		await waitFor(() => expect(mockSet).toHaveBeenCalledWith(false));
		expect(((await screen.findByRole("checkbox")) as HTMLInputElement).checked).toBe(false);
	});

	it("lets an answered operator flip the toggle", async () => {
		mockGet.mockResolvedValue(state({ telemetry_enabled: true }));
		mockSet.mockResolvedValue(state({ telemetry_enabled: false }));
		render(<TelemetryTab />);

		fireEvent.click(await screen.findByRole("checkbox"));

		await waitFor(() => expect(mockSet).toHaveBeenCalledWith(false));
		await waitFor(() =>
			expect((screen.getByRole("checkbox") as HTMLInputElement).checked).toBe(false),
		);
	});

	it("shows the exact payload that is sent", async () => {
		mockGet.mockResolvedValue(state({ telemetry_enabled: true }));
		render(<TelemetryTab />);

		const pre = await screen.findByText(/"runtime": "docker"/);
		expect(JSON.parse(pre.textContent ?? "")).toEqual(payload);
	});

	it("says so and disables the toggle when the environment forbids telemetry", async () => {
		mockGet.mockResolvedValue(state({ telemetry_enabled: true, env_disabled: true }));
		render(<TelemetryTab />);

		expect(await screen.findByRole("status")).toBeTruthy();
		expect((screen.getByRole("checkbox") as HTMLInputElement).disabled).toBe(true);
	});

	it("keeps the prompt and surfaces an error when saving fails", async () => {
		mockGet.mockResolvedValue(state());
		mockSet.mockRejectedValue(new Error("boom"));
		render(<TelemetryTab />);

		fireEvent.click(await screen.findByRole("button", { name: "Share anonymous stats" }));

		await waitFor(() => expect(mockSet).toHaveBeenCalled());
		expect(await screen.findByRole("button", { name: "Share anonymous stats" })).toBeTruthy();
	});
});
