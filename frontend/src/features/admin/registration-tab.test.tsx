import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { LocaleProvider, useT } from "@/i18n/locale-provider";
import RegistrationTab from "./RegistrationTab";

const mockGet = vi.fn();
const mockSet = vi.fn();
vi.mock("./api", () => ({
	adminApi: { getRegistration: () => mockGet(), setRegistration: (m: string) => mockSet(m) },
}));
const { success } = vi.hoisted(() => ({ success: vi.fn() }));
vi.mock("sonner", () => ({ toast: { success, error: vi.fn() } }));

beforeEach(() => {
	mockGet.mockReset();
	window.localStorage.setItem("engram:locale", "de");
});

describe("RegistrationTab", () => {
	it("fetches once across a catalog load and a language switch", async () => {
		mockGet.mockResolvedValue({ registration_mode: "open" });
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
					de: async () => ({ default: { "Failed to load setting": "Laden fehlgeschlagen" } }),
					fr: async () => ({ default: { "Failed to load setting": "Échec du chargement" } }),
				}}
			>
				<Switch />
				<RegistrationTab />
			</LocaleProvider>,
		);
		await waitFor(() => expect(document.documentElement.lang).toBe("de"));
		fireEvent.click(screen.getByRole("button", { name: "french" }));
		await waitFor(() => expect(document.documentElement.lang).toBe("fr"));
		expect(mockGet).toHaveBeenCalledTimes(1);
	});

	// The wire value ("invite_only") is not a word: the toast names the option.
	it("names the chosen mode by its label, not its wire value", async () => {
		window.localStorage.setItem("engram:locale", "en");
		mockGet.mockResolvedValue({ registration_mode: "open" });
		mockSet.mockResolvedValue(undefined);
		render(<RegistrationTab />);
		fireEvent.click(await screen.findByRole("radio", { name: /invite only/iu }));
		await waitFor(() => expect(success).toHaveBeenCalledWith("Registration mode: Invite only"));
	});
});
