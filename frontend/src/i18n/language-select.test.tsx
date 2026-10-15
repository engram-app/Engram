import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { LanguageSelect } from "./language-select";
import { LocaleProvider, useT } from "./locale-provider";

function Probe() {
	const { t } = useT();
	return <p>{t("Hello")}</p>;
}

describe("LanguageSelect: icon-only", () => {
	beforeAll(() => {
		Element.prototype.hasPointerCapture ??= () => false;
		Element.prototype.setPointerCapture ??= () => undefined;
		Element.prototype.releasePointerCapture ??= () => undefined;
		Element.prototype.scrollIntoView ??= () => undefined;
	});

	afterEach(() => window.localStorage.clear());

	it("re-picking the stored language retries a catalog that failed to load", async () => {
		window.localStorage.setItem("engram:locale", "ja");
		let calls = 0;
		const loaders = {
			ja: async () => {
				calls += 1;
				if (calls === 1) {
					throw new Error("chunk failed");
				}
				return { default: { Hello: "こんにちは" } };
			},
		};
		render(
			<LocaleProvider loaders={loaders}>
				<LanguageSelect iconOnly />
				<Probe />
			</LocaleProvider>,
		);
		await waitFor(() => expect(calls).toBe(1));
		expect(screen.getByText("Hello")).toBeInTheDocument();
		// Re-pick 日本語 with the trigger's typeahead (Radix selects the matching
		// item without opening). Opening the popup instead mounted the portal,
		// focus scope and all ten items, then unmounted them: about a third of
		// this test's CPU, which a loaded CI box stretched past the 5 s timeout.
		// The pick still goes through the same onValueChange.
		fireEvent.keyDown(screen.getByLabelText("Language"), { key: "日" });
		expect(await screen.findByText("こんにちは")).toBeInTheDocument();
		expect(calls).toBe(2);
	});
});
