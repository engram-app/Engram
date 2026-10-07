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
		const trigger = screen.getByRole("combobox", { name: /language/iu });
		fireEvent.pointerDown(trigger, { button: 0, ctrlKey: false, pointerType: "mouse" });
		fireEvent.click(await screen.findByRole("option", { name: "日本語" }));
		expect(await screen.findByText("こんにちは")).toBeInTheDocument();
	});
});
