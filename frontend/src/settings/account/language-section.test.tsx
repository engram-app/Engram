import { fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { LocaleProvider } from "@/i18n/locale-provider";
import { LanguageSection } from "./language-section";

function mount() {
	return render(
		<LocaleProvider loaders={{}}>
			<LanguageSection />
		</LocaleProvider>,
	);
}

describe("LanguageSection", () => {
	// Radix Select calls these pointer/scroll APIs, which happy-dom lacks.
	beforeAll(() => {
		Element.prototype.hasPointerCapture ??= () => false;
		Element.prototype.setPointerCapture ??= () => undefined;
		Element.prototype.releasePointerCapture ??= () => undefined;
		Element.prototype.scrollIntoView ??= () => undefined;
	});

	afterEach(() => {
		vi.unstubAllEnvs();
		window.localStorage.clear();
	});

	it("renders its own card with a title and description", () => {
		mount();
		expect(screen.getByRole("heading", { name: "Language" })).toBeInTheDocument();
		expect(screen.getByText("Choose the language Engram uses on this device.")).toBeInTheDocument();
	});

	it("has no visible label of its own, only an accessible name on the trigger", () => {
		mount();
		expect(screen.getAllByText("Language")).toHaveLength(1);
		expect(screen.getByRole("combobox", { name: /language/iu })).toHaveAttribute(
			"aria-label",
			"Language",
		);
	});

	it("lists every locale by its own name, persists a pick and shows it", async () => {
		window.localStorage.clear();
		mount();
		const trigger = screen.getByRole("combobox", { name: /language/iu });
		expect(trigger).toHaveTextContent("English");
		fireEvent.pointerDown(trigger, { button: 0, ctrlKey: false, pointerType: "mouse" });
		expect(await screen.findByRole("option", { name: "English" })).toBeInTheDocument();
		fireEvent.click(screen.getByRole("option", { name: "日本語" }));
		await vi.waitFor(() => expect(window.localStorage.getItem("engram:locale")).toBe("ja"));
		expect(screen.getByRole("combobox", { name: /language/iu })).toHaveTextContent("日本語");
	});

	it("renders nothing outside dev builds", () => {
		vi.stubEnv("DEV", false);
		const { container } = mount();
		expect(screen.queryByRole("combobox")).not.toBeInTheDocument();
		expect(screen.queryByRole("heading", { name: "Language" })).not.toBeInTheDocument();
		expect(container).toBeEmptyDOMElement();
	});
});
