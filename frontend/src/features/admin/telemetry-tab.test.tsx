import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { LocaleProvider, useT } from "@/i18n/locale-provider";
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
	it("shows the toggle ON when nothing has been answered (on by default)", async () => {
		mockGet.mockResolvedValue(state());
		render(<TelemetryTab />);

		expect(((await screen.findByRole("checkbox")) as HTMLInputElement).checked).toBe(true);
		expect(screen.queryByRole("button")).toBeNull();
	});

	it("shows the toggle OFF once the operator turned it off", async () => {
		mockGet.mockResolvedValue(state({ telemetry_enabled: false }));
		render(<TelemetryTab />);

		expect(((await screen.findByRole("checkbox")) as HTMLInputElement).checked).toBe(false);
	});

	it("turns it off from the default state", async () => {
		mockGet.mockResolvedValue(state());
		mockSet.mockResolvedValue(state({ telemetry_enabled: false }));
		render(<TelemetryTab />);

		fireEvent.click(await screen.findByRole("checkbox"));

		await waitFor(() => expect(mockSet).toHaveBeenCalledWith(false));
		await waitFor(() =>
			expect((screen.getByRole("checkbox") as HTMLInputElement).checked).toBe(false),
		);
	});

	it("turns it back on", async () => {
		mockGet.mockResolvedValue(state({ telemetry_enabled: false }));
		mockSet.mockResolvedValue(state({ telemetry_enabled: true }));
		render(<TelemetryTab />);

		fireEvent.click(await screen.findByRole("checkbox"));

		await waitFor(() => expect(mockSet).toHaveBeenCalledWith(true));
		await waitFor(() =>
			expect((screen.getByRole("checkbox") as HTMLInputElement).checked).toBe(true),
		);
	});

	it("shows the exact payload that is sent", async () => {
		mockGet.mockResolvedValue(state());
		render(<TelemetryTab />);

		const pre = await screen.findByText(/"runtime": "docker"/);
		expect(JSON.parse(pre.textContent ?? "")).toEqual(payload);
	});

	it("says so and disables the toggle when the environment forbids telemetry", async () => {
		mockGet.mockResolvedValue(state({ env_disabled: true }));
		render(<TelemetryTab />);

		expect(await screen.findByRole("status")).toBeTruthy();
		const box = screen.getByRole("checkbox") as HTMLInputElement;
		expect(box.disabled).toBe(true);
		// Nothing is sent, so the toggle must not read as "on".
		expect(box.checked).toBe(false);
	});

	it("keeps the toggle where it was when saving fails", async () => {
		mockGet.mockResolvedValue(state());
		mockSet.mockRejectedValue(new Error("boom"));
		render(<TelemetryTab />);

		fireEvent.click(await screen.findByRole("checkbox"));

		await waitFor(() => expect(mockSet).toHaveBeenCalled());
		expect((screen.getByRole("checkbox") as HTMLInputElement).checked).toBe(true);
	});

	it("fetches once across a catalog load and a language switch", async () => {
		window.localStorage.setItem("engram:locale", "de");
		mockGet.mockResolvedValue(state());
		function Switch() {
			const { setLocale } = useT();
			return (
				<button type="button" onClick={() => setLocale("fr")}>
					french
				</button>
			);
		}
		render(
			<LocaleProvider
				loaders={{
					de: async () => ({ default: { "Save failed": "Speichern fehlgeschlagen" } }),
					fr: async () => ({ default: { "Save failed": "Échec de l'enregistrement" } }),
				}}
			>
				<Switch />
				<TelemetryTab />
			</LocaleProvider>,
		);
		await screen.findByRole("checkbox");
		await waitFor(() => expect(document.documentElement.lang).toBe("de"));
		fireEvent.click(screen.getByRole("button", { name: "french" }));
		await waitFor(() => expect(document.documentElement.lang).toBe("fr"));
		expect(mockGet).toHaveBeenCalledTimes(1);
	});
});
