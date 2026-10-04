import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { LocaleProvider } from "@/i18n/locale-provider";
import { AppearanceSection } from "./appearance-section";

const setTheme = vi.fn();
let theme = "system";
vi.mock("@/theme/theme-provider", () => ({
	useTheme: () => ({ theme, resolved: "dark", setTheme }),
}));

describe("AppearanceSection", () => {
	beforeEach(() => {
		vi.clearAllMocks();
		theme = "system";
	});

	it("marks the active theme as pressed", () => {
		render(<AppearanceSection />);
		expect(screen.getByRole("button", { name: /system/iu })).toHaveAttribute(
			"aria-pressed",
			"true",
		);
		expect(screen.getByRole("button", { name: /dark/iu })).toHaveAttribute("aria-pressed", "false");
	});

	it("calls setTheme when a choice is clicked", () => {
		render(<AppearanceSection />);
		fireEvent.click(screen.getByRole("button", { name: /dark/iu }));
		expect(setTheme).toHaveBeenCalledWith("dark");
	});

	it("lists every locale by its own name and persists a pick", () => {
		window.localStorage.clear();
		render(
			<LocaleProvider loaders={{}}>
				<AppearanceSection />
			</LocaleProvider>,
		);
		const select = screen.getByRole("combobox", { name: /language/iu });
		expect(screen.getByRole("option", { name: "日本語" })).toBeInTheDocument();
		expect(screen.getByRole("option", { name: "English" })).toBeInTheDocument();
		fireEvent.change(select, { target: { value: "ja" } });
		expect(window.localStorage.getItem("engram:locale")).toBe("ja");
		expect(select).toHaveValue("ja");
	});
});
