import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import AuthShell from "./auth-shell";

vi.mock("../theme/theme-toggle", () => ({
	default: () => <button type="button">theme</button>,
}));

describe("AuthShell", () => {
	it("renders the Engram wordmark, theme toggle, and children", () => {
		render(
			<AuthShell>
				<p>panel body</p>
			</AuthShell>,
		);
		expect(screen.getByText("Engram")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: /theme/iu })).toBeInTheDocument();
		expect(screen.getByText("panel body")).toBeInTheDocument();
	});

	it("renders a language picker in the top bar", () => {
		render(
			<AuthShell>
				<p>body</p>
			</AuthShell>,
		);
		expect(screen.getByRole("banner")).toContainElement(
			screen.getByRole("combobox", { name: "Language" }),
		);
	});

	it("shows the language picker as an icon, not the current language name", () => {
		render(
			<AuthShell>
				<p>body</p>
			</AuthShell>,
		);
		expect(screen.getByRole("combobox", { name: "Language" })).not.toHaveTextContent("English");
	});

	it("renders the actions slot when provided", () => {
		render(
			<AuthShell actions={<span>Step 1 of 2</span>}>
				<p>body</p>
			</AuthShell>,
		);
		expect(screen.getByText(/step 1 of 2/iu)).toBeInTheDocument();
	});
});
