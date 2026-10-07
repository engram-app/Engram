import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { LocaleProvider } from "./locale-provider";
import { Trans } from "./trans";

describe("Trans", () => {
	it("renders English around a React slot", () => {
		render(<Trans text="Type {word} to confirm" slots={{ word: <code>delete</code> }} />);
		expect(screen.getByText("delete").tagName).toBe("CODE");
		expect(document.body.textContent).toBe("Type delete to confirm");
	});

	it("moves the slot where the translation puts it", async () => {
		window.localStorage.setItem("engram:locale", "ja");
		const loaders = {
			ja: async () => ({ default: { "Type {word} to confirm": "{word}を入力して確認" } }),
		};
		render(
			<LocaleProvider loaders={loaders}>
				<Trans text="Type {word} to confirm" slots={{ word: <code>delete</code> }} />
			</LocaleProvider>,
		);
		await screen.findByText("delete");
		await expect.poll(() => document.body.textContent).toBe("deleteを入力して確認");
	});

	it("keeps an unfilled slot visible", () => {
		render(<Trans text="Hi {who}" slots={{}} />);
		expect(document.body.textContent).toBe("Hi {who}");
	});
});
