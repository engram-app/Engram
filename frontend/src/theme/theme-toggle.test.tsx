import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { LocaleProvider } from "@/i18n/locale-provider";
import ThemeToggle from "./theme-toggle";

let theme = "system";
vi.mock("./theme-provider", () => ({
	useTheme: () => ({ theme, resolved: "dark", setTheme: vi.fn() }),
}));

describe("ThemeToggle label", () => {
	it.each([
		["system", "Theme: system"],
		["light", "Theme: light"],
		["dark", "Theme: dark"],
	])("reads %s in English exactly as before", (value, label) => {
		theme = value;
		render(<ThemeToggle />);
		expect(screen.getByRole("button", { name: label })).toHaveAttribute("title", label);
	});

	it("translates the whole label", async () => {
		theme = "dark";
		window.localStorage.setItem("engram:locale", "de");
		render(
			<LocaleProvider
				loaders={{ de: async () => ({ default: { "Theme: dark": "Design: Dunkel" } }) }}
			>
				<ThemeToggle />
			</LocaleProvider>,
		);
		expect(await screen.findByRole("button", { name: "Design: Dunkel" })).toBeInTheDocument();
	});
});
