import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
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
});
